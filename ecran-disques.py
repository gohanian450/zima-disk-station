#!/usr/bin/env python3
# =====================================================================
#   ZIMA DISK STATION — interface graphique plein écran (HDMI)
#
#   Dessine directement sur l'écran du ZimaBoard (framebuffer /dev/fb0) :
#     • santé SMART, % de vie, température, heures d'utilisation
#     • stockage (système de fichiers, espace libre)
#     • progression de l'effacement / formatage en direct
#
#   Utilisation :
#     sudo python3 ecran-disques.py                 -> affiche sur l'écran HDMI
#     python3 ecran-disques.py --demo 2 --png a.png -> enregistre une image de démo
#     sudo python3 ecran-disques.py --demo 2        -> démo sur l'écran (1, 2, 3 ou 0)
# =====================================================================
import argparse, datetime, fcntl, glob, json, math, mmap, os, re, signal, socket, struct, subprocess, sys, time
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ICI = os.path.dirname(os.path.abspath(__file__))
STATUS_DIR = "/run/effacement"
W, H = 1920, 1080
REFRESH = 2.0
SMART_CACHE = 60

# ------------------------------------------------------------------ compatibilité Pillow < 8.2 (Debian 11)
if not hasattr(ImageDraw.ImageDraw, "rounded_rectangle"):
    def _rounded_rectangle(self, xy, radius=0, fill=None, outline=None, width=1):
        if len(xy) == 2:
            (x0, y0), (x1, y1) = xy
        else:
            x0, y0, x1, y1 = xy
        r = max(0, min(radius, (x1 - x0) / 2, (y1 - y0) / 2))
        d = 2 * r
        coins = (([x0, y0, x0 + d, y0 + d], 180, 270), ([x1 - d, y0, x1, y0 + d], 270, 360),
                 ([x0, y1 - d, x0 + d, y1], 90, 180), ([x1 - d, y1 - d, x1, y1], 0, 90))
        if fill is not None:
            self.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
            self.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
            if r > 0:
                for box, a, b in coins:
                    self.pieslice(box, a, b, fill=fill)
        if outline is not None and width > 0:
            w = width
            if r > 0:
                for box, a, b in coins:
                    self.arc(box, a, b, fill=outline, width=w)
            self.rectangle([x0 + r, y0, x1 - r, y0 + w - 1], fill=outline)
            self.rectangle([x0 + r, y1 - w + 1, x1 - r, y1], fill=outline)
            self.rectangle([x0, y0 + r, x0 + w - 1, y1 - r], fill=outline)
            self.rectangle([x1 - w + 1, y0 + r, x1, y1 - r], fill=outline)
    ImageDraw.ImageDraw.rounded_rectangle = _rounded_rectangle

# ------------------------------------------------------------------ palette
BG_TOP, BG_BOT = (8, 11, 22), (12, 15, 32)
CARD, CARD_LINE = (19, 24, 44), (40, 48, 82)
TXT, TXT2, TXT3 = (238, 241, 250), (150, 160, 192), (92, 102, 138)
CYAN, VIOLET, PINK = (34, 211, 238), (139, 92, 246), (236, 72, 153)
GREEN, LIME = (34, 197, 94), (132, 204, 22)
YELLOW, ORANGE, RED = (250, 204, 21), (249, 115, 22), (239, 68, 68)
BLUE, SLATE = (59, 130, 246), (71, 85, 125)

# ------------------------------------------------------------------ polices
POLICES = {
    "reg":   ["Inter-Regular.ttf", "DejaVuSans.ttf"],
    "med":   ["Inter-Medium.ttf", "DejaVuSans.ttf"],
    "semi":  ["Inter-SemiBold.ttf", "DejaVuSans-Bold.ttf"],
    "bold":  ["Inter-Bold.ttf", "DejaVuSans-Bold.ttf"],
    "dbold": ["InterDisplay-Bold.ttf", "Inter-Bold.ttf", "DejaVuSans-Bold.ttf"],
    "black": ["InterDisplay-Black.ttf", "Inter-Bold.ttf", "DejaVuSans-Bold.ttf"],
    "mono":  ["DejaVuSansMono.ttf"],
}
DOSSIERS = [os.path.join(ICI, "polices"), "/usr/share/fonts/truetype/inter", "/usr/share/fonts/opentype/inter",
            "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF", "/usr/share/fonts"]
_fcache = {}

def F(style, size):
    size = max(8, int(round(size)))
    key = (style, size)
    if key in _fcache:
        return _fcache[key]
    for nom in POLICES[style]:
        for d in DOSSIERS:
            p = os.path.join(d, nom)
            if os.path.isfile(p):
                _fcache[key] = ImageFont.truetype(p, size)
                return _fcache[key]
    _fcache[key] = ImageFont.load_default()
    return _fcache[key]

# ------------------------------------------------------------------ formats
def hum(o):
    o = float(o or 0)
    for u in ("o", "Ko", "Mo", "Go", "To", "Po"):
        if o < 1000 or u == "Po":
            break
        o /= 1000
    if u == "o":
        return f"{int(o)} o"
    s = f"{o:.1f}" if o < 10 else f"{o:.0f}"
    return s.replace(".", ",") + " " + u

def milliers(n):
    return f"{int(n):,}".replace(",", " ")

JOURS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
        "septembre", "octobre", "novembre", "décembre"]

def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def couleur_vie(v):
    if v >= 80: return GREEN
    if v >= 50: return YELLOW
    if v >= 25: return ORANGE
    return RED

def couleur_temp(t):
    return GREEN if t < 45 else (YELLOW if t < 55 else RED)

# ------------------------------------------------------------------ dessin anti-crénelé
SS = 4
_cache = {}

def rrect(w, h, r, fill, outline=None, width=1):
    key = ("rr", w, h, r, fill, outline, width)
    if key not in _cache:
        im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
        ImageDraw.Draw(im).rounded_rectangle([0, 0, w * SS - 1, h * SS - 1], r * SS, fill=fill,
                                             outline=outline, width=width * SS if outline else 0)
        _cache[key] = im.resize((w, h), Image.LANCZOS)
    return _cache[key]

def degrade(w, h, c1, c2, vertical=False):
    key = ("dg", w, h, c1, c2, vertical)
    if key not in _cache:
        g = Image.linear_gradient("L").resize((256, 256))
        if not vertical:
            g = g.rotate(90, expand=True).transpose(Image.FLIP_LEFT_RIGHT)
        g = g.resize((max(1, w), max(1, h)))
        _cache[key] = Image.composite(Image.new("RGBA", (w, h), c2 + (255,)), Image.new("RGBA", (w, h), c1 + (255,)), g)
    return _cache[key]

def barre(w, h, frac, c1, c2, piste=(255, 255, 255, 16)):
    """Barre de progression arrondie avec dégradé."""
    frac = max(0.0, min(1.0, frac))
    im = rrect(w, h, h // 2, piste).copy()
    if frac > 0:
        fw = max(h, int(round(w * frac)))
        masque = rrect(fw, h, h // 2, (255, 255, 255, 255)).getchannel("A")
        rempli = degrade(fw, h, c1, c2).copy()
        rempli.putalpha(masque)
        im.alpha_composite(rempli, (0, 0))
    return im

def anneau(taille, epais, frac, couleur, couleur2=None, piste=(255, 255, 255, 20)):
    key = ("an", taille, epais, round(frac, 3), couleur, couleur2)
    if key in _cache:
        return _cache[key]
    s = taille * SS
    e = epais * SS
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    box = [0, 0, s - 1, s - 1]
    d.ellipse(box, outline=piste, width=e)
    frac = max(0.0, min(1.0, frac))
    if frac > 0:
        arc = Image.new("L", (s, s), 0)
        da = ImageDraw.Draw(arc)
        fin = -90 + 360 * frac
        da.arc(box, -90, fin, fill=255, width=e)
        rr = (s - e) / 2 - 0.5
        for ang in (-90, fin):  # bouts arrondis
            cx = s / 2 + rr * math.cos(math.radians(ang))
            cy = s / 2 + rr * math.sin(math.radians(ang))
            da.ellipse([cx - e / 2, cy - e / 2, cx + e / 2, cy + e / 2], fill=255)
        coul = degrade(s, s, couleur, couleur2 or couleur, vertical=True).copy()
        coul.putalpha(arc)
        im.alpha_composite(coul)
    im = im.resize((taille, taille), Image.LANCZOS)
    _cache[key] = im
    return im

def halo(w, h, r, couleur, force=110, flou=26):
    key = ("halo", w, h, r, couleur, force, flou)
    if key not in _cache:
        m = flou * 2
        im = Image.new("RGBA", (w + 2 * m, h + 2 * m), (0, 0, 0, 0))
        ImageDraw.Draw(im).rounded_rectangle([m, m, m + w, m + h], r, fill=couleur + (force,))
        _cache[key] = (im.filter(ImageFilter.GaussianBlur(flou)), m)
    return _cache[key]

def carte_fond(w, h, r, bord):
    key = ("carte", w, h, r, bord)
    if key not in _cache:
        im = rrect(w, h, r, CARD + (236,), bord + (255,), 2).copy()
        reflet = degrade(w, h, (255, 255, 255), (255, 255, 255), vertical=True).copy()
        a = Image.linear_gradient("L").resize((w, h)).point(lambda v: int(max(0, 255 - v * 3) * 0.06))
        reflet.putalpha(ImageChops.multiply(a, im.getchannel("A")))
        im.alpha_composite(reflet)
        _cache[key] = im
    return _cache[key]

def tronquer(txt, font, maxw):
    if font.getlength(txt) <= maxw:
        return txt
    while txt and font.getlength(txt + "…") > maxw:
        txt = txt[:-1]
    return txt.rstrip() + "…"

def puce(img, x, y, texte, font, fg, bg, padx=12, h=None, point=None, droite=False):
    """Petite étiquette arrondie. Retourne sa largeur."""
    tw = font.getlength(texte)
    extra = (font.size * 0.9) if point else 0
    h = h or int(font.size * 1.9)
    w = int(tw + padx * 2 + extra)
    if droite:
        x -= w
    img.alpha_composite(rrect(w, h, h // 2, bg), (int(x), int(y)))
    d = ImageDraw.Draw(img, "RGBA")
    tx = x + padx
    if point:
        rp = font.size * 0.28
        d.ellipse([tx, y + h / 2 - rp, tx + 2 * rp, y + h / 2 + rp], fill=point)
        tx += extra
    d.text((tx, y + h / 2), texte, font=font, fill=fg, anchor="lm")
    return w

# ------------------------------------------------------------------ arrière-plan
def fond():
    if "fond" in _cache:
        return _cache["fond"]
    im = degrade(W, H, BG_TOP, BG_BOT, vertical=True).copy()
    lum = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(lum)
    d.ellipse([-420, -520, 900, 520], fill=CYAN + (46,))
    d.ellipse([1200, 560, 2400, 1500], fill=VIOLET + (52,))
    d.ellipse([700, 300, 1300, 800], fill=BLUE + (14,))
    lum = lum.filter(ImageFilter.GaussianBlur(170))
    im.alpha_composite(lum)
    pts = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(pts)
    for yy in range(20, H, 36):
        for xx in range(20, W, 36):
            g.point((xx, yy), fill=(255, 255, 255, 22))
    im.alpha_composite(pts)
    _cache["fond"] = im
    return im

def logo(taille):
    key = ("logo", taille)
    if key in _cache:
        return _cache[key]
    s = taille * SS
    im = degrade(s, s, CYAN, VIOLET).copy()
    im.putalpha(rrect(s, s, s // 4, (255, 255, 255, 255)).getchannel("A"))
    d = ImageDraw.Draw(im)
    m, lw = s * 0.24, int(s * 0.055)
    d.rounded_rectangle([m, s * 0.28, s - m, s * 0.72], s * 0.07, outline=(255, 255, 255, 255), width=lw)
    d.line([m + s * 0.08, s * 0.5, s * 0.55, s * 0.5], fill=(255, 255, 255, 170), width=lw)
    r = s * 0.045
    d.ellipse([s - m - s * 0.14 - r, s * 0.5 - r, s - m - s * 0.14 + r, s * 0.5 + r], fill=(255, 255, 255, 255))
    im = im.resize((taille, taille), Image.LANCZOS)
    _cache[key] = im
    return im

# ------------------------------------------------------------------ collecte des données
def run(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

SYSTEME = ("/", "/boot", "/boot/efi", "/usr", "/var", "/DATA")

def points_montage(dev):
    pts = [dev.get("mountpoint")] + list(dev.get("mountpoints") or [])
    for c in dev.get("children") or []:
        pts += points_montage(c)
    return [p for p in pts if p]

_smart = {}

def lire_smart(path):
    now = time.time()
    if path in _smart and now - _smart[path][0] < SMART_CACHE:
        return _smart[path][1]
    r = {"etat": "absent", "vie": None, "secteurs": None, "temp": None, "heures": None}
    if run(["which", "smartctl"]).strip():
        j = {}
        for extra in ([], ["-d", "sat"]):
            try:
                j = json.loads(run(["smartctl", "-j", "-a"] + extra + [path]) or "{}")
            except ValueError:
                j = {}
            if "smart_status" in j:
                break
        r["etat"] = "?"
        if "smart_status" in j:
            r["etat"] = "BON" if j["smart_status"].get("passed") else "DANGER"
        r["temp"] = (j.get("temperature") or {}).get("current")
        r["heures"] = (j.get("power_on_time") or {}).get("hours")
        nv = j.get("nvme_smart_health_information_log")
        if nv and nv.get("percentage_used") is not None:
            r["vie"] = max(0, 100 - int(nv["percentage_used"]))
        table = {a.get("id"): a for a in (j.get("ata_smart_attributes") or {}).get("table", [])}
        if r["vie"] is None:
            for i in (231, 233, 177, 202, 169):
                v = (table.get(i) or {}).get("value")
                if v is not None and v <= 100:
                    r["vie"] = int(v)
                    break
        if r["vie"] is None and 5 in table:
            r["secteurs"] = int((table[5].get("raw") or {}).get("value", 0))
            if r["secteurs"] > 50:
                r["etat"] = "DANGER"
    _smart[path] = (now, r)
    return r

def lire_statut(nom):
    p = os.path.join(STATUS_DIR, nom)
    if not os.path.isfile(p):
        return {"has": False, "pct": 0, "msg": "", "reste": None}
    try:
        parts = open(p, encoding="utf-8").read().strip().split("|")
    except OSError:
        return {"has": False, "pct": 0, "msg": "", "reste": None}
    parts += ["", "", ""]
    pct = int(parts[0]) if parts[0].lstrip("-").isdigit() else 0
    reste = int(parts[2]) if parts[2].isdigit() else None
    return {"has": True, "pct": pct, "msg": parts[1], "reste": reste}

def collecter():
    out = run(["lsblk", "-J", "-b", "-o", "NAME,PATH,TYPE,TRAN,SIZE,MODEL,FSTYPE,LABEL,FSAVAIL,FSSIZE,MOUNTPOINT"])
    try:
        devs = json.loads(out or "{}").get("blockdevices", [])
    except ValueError:
        devs = []
    disques = []
    for d in devs:
        tran = (d.get("tran") or "").lower()
        path = d.get("path") or "/dev/" + d.get("name", "")
        if d.get("type") != "disk" or tran not in ("sata", "usb", "nvme"):
            continue
        if path.startswith("/dev/mmcblk") or any(p in SYSTEME or p.startswith("/boot") for p in points_montage(d)):
            continue
        parts = [d] + list(d.get("children") or [])
        fs = next((p for p in parts if p.get("fstype")), {})
        mnt = next((p for p in parts if p.get("fssize")), {})
        info = {"path": path, "nom": path.split("/")[-1], "tran": tran.upper(), "taille": int(d.get("size") or 0),
                "modele": (d.get("model") or "Disque").strip(), "fs": fs.get("fstype") or "", "label": fs.get("label") or "",
                "libre": int(mnt["fsavail"]) if mnt.get("fsavail") else None,
                "total": int(mnt["fssize"]) if mnt.get("fssize") else None}
        info.update(lire_smart(path))
        info.update(lire_statut(info["nom"]))
        disques.append(info)
    return disques

def infos_systeme(demo):
    if demo is not None:
        return {"ip": "192.168.1.42", "cpu": 46, "ram": "1,3 / 8,0 Go", "up": "2 h 14 min"}
    ip = ""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80)); ip = s.getsockname()[0]; s.close()
    except OSError:
        pass
    cpu = None
    try:
        cpu = int(open("/sys/class/thermal/thermal_zone0/temp").read()) // 1000
    except (OSError, ValueError):
        pass
    ram = ""
    try:
        m = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo")}
        t, a = m["MemTotal"] / 1048576, m["MemAvailable"] / 1048576
        ram = f"{t - a:.1f} / {t:.1f} Go".replace(".", ",")
    except (OSError, KeyError, ValueError):
        pass
    up = ""
    try:
        s = int(float(open("/proc/uptime").read().split()[0]))
        up = f"{s // 86400} j {s % 86400 // 3600} h" if s >= 86400 else f"{s // 3600} h {s % 3600 // 60:02d} min"
    except (OSError, ValueError):
        pass
    return {"ip": ip, "cpu": cpu, "ram": ram, "up": up}

def donnees_demo(n):
    if n == 0:
        return []
    base = [
        dict(path="/dev/sda", nom="sda", tran="SATA", taille=1000204886016, modele="Samsung SSD 870 EVO 1TB",
             etat="BON", vie=96, secteurs=None, temp=33, heures=1203),
        dict(path="/dev/sdb", nom="sdb", tran="SATA", taille=500107862016, modele="Crucial MX500 500GB",
             etat="BON", vie=71, secteurs=None, temp=38, heures=9874),
        dict(path="/dev/sdc", nom="sdc", tran="USB", taille=2000398934016, modele="WD Blue WD20EZBX 2TB",
             etat="BON", vie=None, secteurs=0, temp=41, heures=22410),
        dict(path="/dev/sdd", nom="sdd", tran="USB", taille=240057409536, modele="Kingston A400 240GB",
             etat="BON", vie=88, secteurs=None, temp=36, heures=4120),
    ]
    vide = dict(fs="", label="", libre=None, total=None, has=False, pct=0, msg="", reste=None)
    for d in base:
        d.update(vide)
    if n == 1:
        base[0].update(fs="ext4", label="DONNEES", libre=612400000000, total=983900000000)
        base[1].update(fs="ntfs", label="BACKUP")
        base[2].update(fs="exfat", label="PHOTOS", libre=1430000000000, total=2000000000000)
        return base[:3]
    if n == 2:
        base[0].update(has=True, pct=62, msg="Écriture de zéros · 412 Mo/s · 15 min restantes", reste=395000000000)
        base[1].update(has=True, pct=87, msg="Écriture de zéros · 395 Mo/s · 3 min restantes", reste=67000000000)
        base[2].update(has=True, pct=23, msg="Écriture de zéros · 162 Mo/s · 2h38 restantes", reste=1597000000000)
        base[3].update(has=True, pct=100, msg="Terminé · ext4 « DISQUE4 »", reste=0, fs="ext4", label="DISQUE4")
        return base
    base[0].update(has=True, pct=100, msg="Terminé · ext4 « DISQUE1 »", reste=0, fs="ext4", label="DISQUE1")
    base[1].update(has=True, pct=100, msg="Terminé · ext4 « DISQUE2 »", reste=0, fs="ext4", label="DISQUE2")
    base[2].update(etat="DANGER", secteurs=148, temp=57, has=True, pct=45,
                   msg="Écriture de zéros · 118 Mo/s · 2h41 restantes", reste=1100000000000)
    return base[:3]

# ------------------------------------------------------------------ états
def etat_disque(d):
    if d["has"] and d["msg"].startswith("ERREUR"):
        return "erreur"
    if d["etat"] == "DANGER":
        return "danger"
    if d["has"] and d["pct"] >= 100:
        return "fini"
    if d["has"]:
        return "cours"
    return "pret"

STYLE = {  # couleur, texte du badge, bordure, halo
    "pret":   (BLUE,  "PRÊT",     CARD_LINE, None),
    "cours":  (CYAN,  "EN COURS", (34, 120, 150), CYAN),
    "fini":   (GREEN, "TERMINÉ",  (30, 120, 70), GREEN),
    "danger": (RED,   "DANGER",   (150, 45, 55), RED),
    "erreur": (RED,   "ERREUR",   (150, 45, 55), RED),
}

# ------------------------------------------------------------------ carte disque
def dessiner_carte(img, x, y, w, h, d, s):
    st = etat_disque(d)
    coul, badge, bord, lueur = STYLE[st]
    r = int(22 * s)
    if lueur:
        g, m = halo(w, h, r, lueur, 70, int(24 * s))
        img.alpha_composite(g, (x - m, y - m))
    img.alpha_composite(carte_fond(w, h, r, bord), (x, y))
    dr = ImageDraw.Draw(img, "RGBA")
    p = int(28 * s)
    X0, X1 = x + p, x + w - p

    # --- ligne du haut : SDA · SATA · capacité        [badge]
    fy = y + int(22 * s)
    ch = int(30 * s)
    cx = X0
    cx += puce(img, cx, fy, d["nom"].upper(), F("bold", 15 * s), TXT, (255, 255, 255, 22), h=ch) + int(8 * s)
    cx += puce(img, cx, fy, d["tran"], F("semi", 14 * s), TXT2, (255, 255, 255, 10), h=ch) + int(8 * s)
    puce(img, cx, fy, hum(d["taille"]), F("semi", 14 * s), YELLOW, YELLOW + (26,), h=ch)
    puce(img, X1, fy, badge, F("bold", 14 * s), coul, coul + (34,), h=ch, point=coul, droite=True)

    # --- modèle + sous-titre
    dr.text((X0, y + int(62 * s)), tronquer(d["modele"], F("semi", 28 * s), X1 - X0), font=F("semi", 28 * s), fill=TXT, anchor="la")
    sous = d["path"]
    if d.get("heures") is not None:
        sous += f"   ·   {milliers(d['heures'])} h d'utilisation"
    dr.text((X0, y + int(96 * s)), tronquer(sous, F("reg", 17 * s), X1 - X0), font=F("reg", 17 * s), fill=TXT3, anchor="la")

    # --- anneau de vie
    ta = int(112 * s)
    ay = y + int(130 * s)
    if d.get("vie") is not None:
        v = d["vie"]; c = couleur_vie(v)
        img.alpha_composite(anneau(ta, int(11 * s), v / 100, c, mix(c, (255, 255, 255), 0.35)), (X0, ay))
        val, lab = f"{v}%", "VIE"
    elif d.get("secteurs") is not None:
        n = d["secteurs"]; c = GREEN if n == 0 else RED
        img.alpha_composite(anneau(ta, int(11 * s), 1.0, c, mix(c, (255, 255, 255), 0.35)), (X0, ay))
        val, lab = milliers(n), "SECTEURS HS"
    else:
        img.alpha_composite(anneau(ta, int(11 * s), 0, SLATE), (X0, ay))
        val, lab, c = "—", "VIE", TXT3
    dr.text((X0 + ta / 2, ay + ta / 2 - 6 * s), val, font=F("dbold", 30 * s if len(val) < 5 else 24 * s), fill=TXT, anchor="mm")
    dr.text((X0 + ta / 2, ay + ta / 2 + 20 * s), lab, font=F("semi", 11 * s), fill=TXT3, anchor="mm")

    # --- statistiques à droite de l'anneau
    sx = X0 + ta + int(30 * s)
    colw = (X1 - sx) / 2
    def stat(cx, cy, label, valeur, couleur=TXT, pt=None):
        dr.text((cx, cy), label, font=F("semi", 12 * s), fill=TXT3, anchor="la")
        tx = cx
        if pt:
            rr = 5 * s
            dr.ellipse([tx, cy + 31 * s - rr, tx + 2 * rr, cy + 31 * s + rr], fill=pt)
            tx += 16 * s
        dr.text((tx, cy + 18 * s), tronquer(valeur, F("semi", 22 * s), colw - 12 * s - (tx - cx)), font=F("semi", 22 * s), fill=couleur, anchor="la")

    sy = y + int(132 * s)
    etat_txt = {"BON": ("Bon", GREEN), "DANGER": ("À remplacer", RED), "absent": ("SMART absent", YELLOW)}.get(d["etat"], ("Inconnu", TXT2))
    stat(sx, sy, "SANTÉ", etat_txt[0], etat_txt[1], pt=etat_txt[1])
    if d.get("temp") is not None:
        stat(sx + colw, sy, "TEMPÉRATURE", f"{d['temp']} °C", couleur_temp(d["temp"]))
    else:
        stat(sx + colw, sy, "TEMPÉRATURE", "—", TXT3)
    sy2 = y + int(186 * s)
    if d["fs"]:
        stat(sx, sy2, "SYSTÈME DE FICHIERS", d["fs"] + (f"  « {d['label']} »" if d["label"] else ""))
    else:
        stat(sx, sy2, "SYSTÈME DE FICHIERS", "Vierge", TXT2)
    if d.get("total"):
        stat(sx + colw, sy2, "ESPACE LIBRE", f"{hum(d['libre'])} / {hum(d['total'])}")
        used = 1 - d["libre"] / d["total"]
        img.alpha_composite(barre(int(X1 - sx), int(7 * s), used, VIOLET, PINK), (int(sx), y + int(236 * s)))
    else:
        stat(sx + colw, sy2, "ESPACE LIBRE", "Non monté" if d["fs"] else "—", TXT3)
        img.alpha_composite(barre(int(X1 - sx), int(7 * s), 0, VIOLET, PINK), (int(sx), y + int(236 * s)))

    # --- séparateur
    ly = y + int(260 * s)
    img.alpha_composite(rrect(X1 - X0, max(1, int(s)), 0, (255, 255, 255, 22)), (X0, ly))

    # --- effacement
    ty = y + int(274 * s)
    by = ty + int(50 * s)
    morceaux = d["msg"].split(" · ")
    if st == "cours" or (st in ("danger", "erreur") and d["has"] and d["pct"] < 100 and not d["msg"].startswith("ERREUR")):
        etape = morceaux[0]
        details = "  ·  ".join(morceaux[1:])
        if d.get("reste"):
            details += ("  ·  " if details else "") + f"reste {hum(d['reste'])}"
        pc = f"{d['pct']} %"
        fpc = F("dbold", 34 * s)
        dr.text((X1, ty + 16 * s), pc, font=fpc, fill=CYAN, anchor="rm")
        dispo = X1 - X0 - fpc.getlength(pc) - 20 * s
        dr.text((X0, ty), tronquer(etape.upper(), F("bold", 13 * s), dispo), font=F("bold", 13 * s), fill=CYAN, anchor="la")
        dr.text((X0, ty + 18 * s), tronquer(details, F("med", 16 * s), dispo), font=F("med", 16 * s), fill=TXT2, anchor="la")
        img.alpha_composite(barre(X1 - X0, int(12 * s), d["pct"] / 100, CYAN, VIOLET), (X0, by))
    elif st == "fini" or (d["has"] and d["pct"] >= 100):
        dr.text((X1, ty + 16 * s), "100 %", font=F("dbold", 34 * s), fill=GREEN, anchor="rm")
        dr.text((X0, ty), "EFFACÉ ET FORMATÉ", font=F("bold", 13 * s), fill=GREEN, anchor="la")
        fin = (morceaux[1] if len(morceaux) > 1 else "") + "  ·  prêt à débrancher"
        dr.text((X0, ty + 18 * s), fin.strip(" ·"), font=F("med", 16 * s), fill=TXT2, anchor="la")
        img.alpha_composite(barre(X1 - X0, int(12 * s), 1.0, GREEN, LIME), (X0, by))
    elif d["has"] and d["msg"].startswith("ERREUR"):
        dr.text((X0, ty), "EFFACEMENT INTERROMPU", font=F("bold", 13 * s), fill=RED, anchor="la")
        dr.text((X0, ty + 18 * s), tronquer(d["msg"], F("med", 16 * s), X1 - X0), font=F("med", 16 * s), fill=TXT2, anchor="la")
        img.alpha_composite(barre(X1 - X0, int(12 * s), d["pct"] / 100, RED, ORANGE), (X0, by))
    else:
        dr.text((X0, ty), "EFFACEMENT", font=F("bold", 13 * s), fill=TXT3, anchor="la")
        dr.text((X0, ty + 18 * s), "En attente  ·  prêt à être effacé", font=F("med", 16 * s), fill=TXT2, anchor="la")
        img.alpha_composite(barre(X1 - X0, int(12 * s), 0, CYAN, VIOLET), (X0, by))

def dessiner_vide(img, x, y, w, h, s):
    """Emplacement libre (pointillés)."""
    r = int(22 * s)
    img.alpha_composite(rrect(w, h, r, (255, 255, 255, 5)), (x, y))
    cal = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(cal)
    c = (255, 255, 255, 40)
    pas, trait = int(14 * s), int(8 * s)
    for xx in range(x + r, x + w - r, pas):
        dr.line([xx, y, min(xx + trait, x + w - r), y], fill=c, width=2)
        dr.line([xx, y + h - 1, min(xx + trait, x + w - r), y + h - 1], fill=c, width=2)
    for yy in range(y + r, y + h - r, pas):
        dr.line([x, yy, x, min(yy + trait, y + h - r)], fill=c, width=2)
        dr.line([x + w - 1, yy, x + w - 1, min(yy + trait, y + h - r)], fill=c, width=2)
    for (ax, ay, a0) in ((x, y, 180), (x + w - 2 * r, y, 270), (x, y + h - 2 * r, 90), (x + w - 2 * r, y + h - 2 * r, 0)):
        dr.arc([ax, ay, ax + 2 * r, ay + 2 * r], a0, a0 + 90, fill=c, width=2)
    cx, cy, rr = x + w / 2, y + h / 2 - 22 * s, 30 * s
    dr.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=(255, 255, 255, 40), width=2)
    dr.line([cx - 11 * s, cy, cx + 11 * s, cy], fill=(255, 255, 255, 90), width=max(2, int(3 * s)))
    dr.line([cx, cy - 11 * s, cx, cy + 11 * s], fill=(255, 255, 255, 90), width=max(2, int(3 * s)))
    dr.text((cx, cy + 54 * s), "Emplacement libre", font=F("semi", 20 * s), fill=TXT3 + (255,), anchor="mm")
    dr.text((cx, cy + 80 * s), "Branche un disque SATA ou USB", font=F("reg", 15 * s), fill=(80, 90, 124, 255), anchor="mm")
    img.alpha_composite(cal)

# ------------------------------------------------------------------ écran complet
def tuile(img, x, y, w, h, label, valeur, couleur):
    img.alpha_composite(carte_fond(w, h, 18, CARD_LINE), (x, y))
    dr = ImageDraw.Draw(img, "RGBA")
    img.alpha_composite(rrect(5, h - 44, 2, couleur + (255,)), (x + 22, y + 22))
    dr.text((x + 44, y + 24), label, font=F("semi", 14), fill=TXT3, anchor="la")
    dr.text((x + 42, y + h - 20), valeur, font=F("black", 46), fill=TXT if valeur != "0" else TXT3, anchor="ls")

def rendre(disques, sysi, t):
    img = fond().copy()
    dr = ImageDraw.Draw(img, "RGBA")
    M = 56

    # --- en-tête
    img.alpha_composite(logo(78), (M, 40))
    dr.text((M + 100, 44), "Zima Disk Station", font=F("black", 46), fill=TXT, anchor="la")
    dr.text((M + 102, 100), "Station d'effacement  ·  santé des disques", font=F("med", 20), fill=TXT2, anchor="la")
    now = datetime.datetime.now()
    dr.text((W - M, 38), now.strftime("%H:%M"), font=F("black", 56), fill=TXT, anchor="ra")
    date = f"{JOURS[now.weekday()]} {now.day} {MOIS[now.month - 1]}"
    dr.text((W - M - 160, 64), date.capitalize(), font=F("med", 19), fill=TXT2, anchor="rm")
    pul = 0.55 + 0.45 * math.sin(t * 3)
    puce(img, W - M - 160, 86, f"EN DIRECT  ·  {sysi['ip'] or 'hors ligne'}", F("semi", 13), TXT2,
         (255, 255, 255, 12), h=28, point=mix(BG_BOT, GREEN, pul), droite=True)

    # --- tuiles de résumé
    etats = [etat_disque(d) for d in disques]
    actifs = [d for d in disques if d["has"] and not d["msg"].startswith("ERREUR")]
    encours = sum(1 for d in actifs if d["pct"] < 100)
    finis = sum(1 for d in actifs if d["pct"] >= 100)
    alertes = sum(1 for e in etats if e in ("danger", "erreur"))
    ty, th, tw, gap = 148, 104, 236, 20
    for i, (lab, val, c) in enumerate((("DISQUES", len(disques), BLUE), ("EN COURS", encours, CYAN),
                                       ("TERMINÉS", finis, GREEN), ("ALERTES", alertes, RED))):
        tuile(img, M + i * (tw + gap), ty, tw, th, lab, str(val), c)
    gx = M + 4 * (tw + gap)
    gw = W - M - gx
    img.alpha_composite(carte_fond(gw, th, 18, CARD_LINE), (gx, ty))
    dr.text((gx + 28, ty + 24), "PROGRESSION GLOBALE", font=F("semi", 14), fill=TXT3, anchor="la")
    if actifs:
        moy = sum(d["pct"] for d in actifs) / len(actifs)
        c1, c2 = (GREEN, LIME) if moy >= 100 else (CYAN, VIOLET)
        dr.text((gx + gw - 28, ty + 20), f"{moy:.0f} %", font=F("black", 40), fill=c1, anchor="ra")
        dr.text((gx + 28, ty + 48), f"{finis} disque{'s' if finis > 1 else ''} terminé{'s' if finis > 1 else ''} sur {len(actifs)}",
                font=F("med", 17), fill=TXT2, anchor="la")
        img.alpha_composite(barre(gw - 56, 14, moy / 100, c1, c2), (gx + 28, ty + th - 34))
    else:
        dr.text((gx + 28, ty + 48), "Aucun effacement en cours", font=F("med", 17), fill=TXT2, anchor="la")
        img.alpha_composite(barre(gw - 56, 14, 0, CYAN, VIOLET), (gx + 28, ty + th - 34))

    # --- grille des disques
    top, bas = 280, H - 72
    if not disques:
        cw, chh = 1100, bas - top - 60
        cx0 = (W - cw) // 2
        img.alpha_composite(carte_fond(cw, chh, 28, CARD_LINE), (cx0, top + 20))
        cx, cy = W / 2, top + 20 + chh / 2 - 70
        g, m = halo(150, 150, 75, CYAN, 90, 40)
        img.alpha_composite(g, (int(cx - 75 - m), int(cy - 75 - m)))
        img.alpha_composite(logo(150), (int(cx - 75), int(cy - 75)))
        dr.text((cx, cy + 130), "Branche un SSD ou un disque dur", font=F("black", 44), fill=TXT, anchor="mm")
        dr.text((cx, cy + 180), "SATA ou dock USB  ·  il apparaîtra ici automatiquement", font=F("med", 22), fill=TXT2, anchor="mm")
    else:
        n = len(disques)
        cols, rows = (2, 2) if n <= 4 else ((3, 2) if n <= 6 else (4, 2))
        gap = 24
        cw = (W - 2 * M - (cols - 1) * gap) // cols
        chh = (bas - top - (rows - 1) * gap) // rows
        s = max(0.62, min(chh / 345, cw / 640, 1.15))
        for k in range(cols * rows):
            x = M + (k % cols) * (cw + gap)
            y = top + (k // cols) * (chh + gap)
            if k < n:
                dessiner_carte(img, x, y, cw, chh, disques[k], s)
            else:
                dessiner_vide(img, x, y, cw, chh, s)
        if n > cols * rows:
            dr.text((W - M, bas + 4), f"+ {n - cols * rows} autre(s) disque(s) non affiché(s)", font=F("med", 15), fill=YELLOW, anchor="ra")

    # --- pied de page
    fy = H - 40
    morceaux = []
    if sysi.get("cpu") is not None:
        morceaux.append(("CPU", f"{sysi['cpu']} °C"))
    if sysi.get("ram"):
        morceaux.append(("RAM", sysi["ram"]))
    if sysi.get("up"):
        morceaux.append(("ALLUMÉ DEPUIS", sysi["up"]))
    fx = M
    for lab, val in morceaux:
        dr.text((fx, fy), lab, font=F("semi", 13), fill=TXT3, anchor="lm")
        fx += F("semi", 13).getlength(lab) + 10
        dr.text((fx, fy), val, font=F("semi", 16), fill=TXT2, anchor="lm")
        fx += F("semi", 16).getlength(val) + 40
    cmd = f"sudo {os.environ.get('ZDS_CHEMIN', ICI)}/effacer-disques.sh"
    puce(img, W - M, fy - 16, cmd, F("mono", 15), CYAN, CYAN + (20,), h=32, droite=True)
    dr.text((W - M - F("mono", 15).getlength(cmd) - 40, fy), "EFFACER LES DISQUES", font=F("semi", 13), fill=TXT3, anchor="rm")
    return img

# ------------------------------------------------------------------ framebuffer
class Ecran:
    FBIOGET_VSCREENINFO, FBIOGET_FSCREENINFO, FBIOPAN_DISPLAY, FBIOBLANK = 0x4600, 0x4602, 0x4606, 0x4611
    KDSETMODE, KD_TEXT, KD_GRAPHICS = 0x4B3A, 0, 1

    def __init__(self, dev="/dev/fb0", tty="/dev/tty1"):
        self.f = open(dev, "r+b", buffering=0)
        var = fcntl.ioctl(self.f, self.FBIOGET_VSCREENINFO, bytes(160))
        v = struct.unpack("8I", var[:32])
        self.w, self.h, self.bpp = v[0], v[1], v[6]
        rouge = struct.unpack("I", var[32:36])[0]
        fix = fcntl.ioctl(self.f, self.FBIOGET_FSCREENINFO, bytes(80))
        self.stride = struct.unpack("I", fix[48:52])[0] or self.w * self.bpp // 8
        self.ordre = "BGRX" if rouge == 16 else "RGBX"
        # infos pour forcer le rafraîchissement (pilotes Intel i915 : sinon l'image ne s'affiche pas)
        v2 = bytearray(var)
        v2[16:24] = bytes(8)                       # xoffset = yoffset = 0
        self.var = bytes(v2)
        self.mm = None
        try:
            self.mm = mmap.mmap(self.f.fileno(), self.stride * self.h, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        except (OSError, ValueError):
            self.mm = None
        try:
            fcntl.ioctl(self.f, self.FBIOBLANK, 0)  # réveille l'écran s'il est en veille
        except OSError:
            pass
        self.premier = True
        self.vw, self.vh = self.zone_visible()
        self.tty = None
        try:
            self.tty = os.open(tty, os.O_RDWR)
            fcntl.ioctl(self.tty, self.KDSETMODE, self.KD_GRAPHICS)  # le texte de la console ne recouvre plus l'image
        except OSError:
            self.tty = None

    def zone_visible(self):
        """Résolution réellement affichée par l'écran branché (peut être plus petite que /dev/fb0)."""
        meilleur = None
        for c in sorted(glob.glob("/sys/class/drm/card*-*")):
            try:
                if open(c + "/status").read().strip() != "connected":
                    continue
                for ligne in open(c + "/modes"):
                    m = re.match(r"(\d+)x(\d+)", ligne.strip())
                    if not m:
                        continue
                    mw, mh = int(m.group(1)), int(m.group(2))
                    if mw <= self.w and mh <= self.h and (meilleur is None or mw * mh > meilleur[0] * meilleur[1]):
                        meilleur = (mw, mh)
            except OSError:
                continue
        return meilleur or (self.w, self.h)

    def afficher(self, img):
        img = img.convert("RGB")
        if (self.vw, self.vh) != (self.w, self.h):
            # l'écran n'affiche qu'une partie du framebuffer : on y loge toute l'image, proportions gardées
            r = min(self.vw / img.width, self.vh / img.height)
            petite = img.resize((max(1, int(img.width * r)), max(1, int(img.height * r))), Image.LANCZOS)
            img = Image.new("RGB", (self.w, self.h), BG_TOP)
            img.paste(petite, ((self.vw - petite.width) // 2, (self.vh - petite.height) // 2))
        elif img.size != (self.w, self.h):
            img = img.resize((self.w, self.h), Image.BICUBIC)
        if self.bpp == 32:
            raw = img.tobytes("raw", self.ordre)
        elif self.bpp == 16:
            raw = img.tobytes("raw", "BGR;16")
        else:
            raw = img.tobytes("raw", "BGR")
        ligne = self.w * self.bpp // 8
        if self.stride != ligne:
            buf = bytearray(self.stride * self.h)
            for yy in range(self.h):
                buf[yy * self.stride: yy * self.stride + ligne] = raw[yy * ligne:(yy + 1) * ligne]
            raw = bytes(buf)
        if self.mm is not None:
            self.mm.seek(0)
            self.mm.write(raw)
        else:
            self.f.seek(0)
            self.f.write(raw)
        try:
            fcntl.ioctl(self.f, self.FBIOPAN_DISPLAY, self.var)   # force l'affichage de la nouvelle image
        except OSError:
            pass
        if self.premier:
            self.premier = False
            print(f"Premier affichage envoyé : écran {self.vw}x{self.vh}, framebuffer {self.w}x{self.h}, {self.bpp} bits, "
                  f"{'mmap' if self.mm is not None else 'write'}, ordre {self.ordre}", flush=True)

    def fermer(self):
        if self.tty is not None:
            try:
                fcntl.ioctl(self.tty, self.KDSETMODE, self.KD_TEXT)
            except OSError:
                pass

# ------------------------------------------------------------------ programme
def main():
    ap = argparse.ArgumentParser(description="ZIMA DISK STATION")
    ap.add_argument("--demo", type=int, choices=[0, 1, 2, 3])
    ap.add_argument("--png", help="enregistre une seule image au lieu d'afficher")
    ap.add_argument("--fb", default="/dev/fb0")
    a = ap.parse_args()

    def donnees():
        return donnees_demo(a.demo) if a.demo is not None else collecter()

    if a.png:
        rendre(donnees(), infos_systeme(a.demo), time.time()).convert("RGB").save(a.png)
        print("Image enregistrée :", a.png)
        return

    # attend que l'écran HDMI soit détecté (branché après le démarrage, ou lent à s'initialiser)
    signale = False
    while True:
        try:
            ecran = Ecran(a.fb)
            break
        except OSError as e:
            if not signale:
                print(f"En attente de l'écran {a.fb} ({e})…", file=sys.stderr)
                signale = True
            time.sleep(3)

    def stop(*_):
        ecran.fermer()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while True:
        t0 = time.time()
        try:
            ecran.afficher(rendre(donnees(), infos_systeme(a.demo), t0))
        except Exception as e:  # on ne plante jamais l'écran pour une erreur passagère
            print("Erreur d'affichage :", e, file=sys.stderr)
        time.sleep(max(0.3, REFRESH - (time.time() - t0)))

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate SwiftUI layer shapes (app/*Art.swift) from the Illustrator artboards in this folder.

Each Illustrator layer becomes an `ArtLayer` (see app/ArtLayer.swift): its filled paths in artboard
points (origin top-left, y down), with text converted to glyph outlines from the font embedded in the .ai.
Layers are emitted bottom to top; empty layers are skipped.

Only works on .ai files saved with "Create PDF Compatible File" (Illustrator's default), and only on
filled paths and text: strokes, gradients, images and symbols raise an error (expand them in Illustrator).

Usage (needs PyMuPDF and fontTools):
    python3 design/ai_to_swift.py
Then run `xcodegen` in app/ if a new output file was added.
"""
import io
import re
from pathlib import Path

import fitz  # PyMuPDF
from fontTools.cffLib import CFFFontSet
from fontTools.pens.recordingPen import RecordingPen

ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT.parent / "app"

# Illustrator layer name -> Swift property name. Unlisted non-empty layers get a name derived from theirs.
ARTBOARDS = [
    dict(src="ProbeHome.ai", out="HomeArt.swift", enum="HomeArt", layers={
        "Layer 2": "background",
        "Layer 3": "monster",
        "Layer 4": "eyeWhite",
        "Layer 5": "iris",
        "Layer 6": "pupil",
        "Layer 8": "title",
    }),
    dict(src="MainScreen.ai", out="MainArt.swift", enum="MainArt", layers={
        "Layer 1": "background",
        "Layer 2": "findCard",
        "Layer 5": "findLabel",
        "Layer 3": "findEyes",
        "Layer 4": "findPupils",
        "Layer 6": "analyzeCard",
        "Layer 7": "analyzeLabel",
        "Layer 8": "magnifier",
        "Layer 9": "magnifierLens",
    }),
]

IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def mul(m1, m2):
    """PDF matrix product m1 × m2 (apply m1, then m2)."""
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (a1 * a2 + b1 * c2, a1 * b2 + b1 * d2,
            c1 * a2 + d1 * c2, c1 * b2 + d1 * d2,
            e1 * a2 + f1 * c2 + e2, e1 * b2 + f1 * d2 + f2)


def apply(m, x, y):
    a, b, c, d, e, f = m
    return (a * x + c * y + e, b * x + d * y + f)


# --- content stream tokenizer -------------------------------------------------------------------

DELIMS = b"()<>[]{}/%"
WS = b" \t\r\n\f\0"


def read_string(data, i):
    """Literal string starting after '(' at data[i]; returns (bytes, index after ')')."""
    out, depth = bytearray(), 1
    escapes = {ord("n"): 10, ord("r"): 13, ord("t"): 9, ord("b"): 8, ord("f"): 12}
    while True:
        ch = data[i]
        i += 1
        if ch == ord("\\"):
            nxt = data[i]
            if chr(nxt) in "01234567":
                j = i
                while j < i + 3 and chr(data[j]) in "01234567":
                    j += 1
                out.append(int(data[i:j], 8) & 0xFF)
                i = j
            elif nxt in (10, 13):  # line continuation
                i += 1
            else:
                out.append(escapes.get(nxt, nxt))
                i += 1
        elif ch == ord("("):
            depth += 1
            out.append(ch)
        elif ch == ord(")"):
            depth -= 1
            if depth == 0:
                return bytes(out), i
            out.append(ch)
        else:
            out.append(ch)


def tokens(data):
    """Yields (operator, operands) for each operator in a content stream."""
    i, n, operands, stack = 0, len(data), [], []
    while i < n:
        ch = data[i]
        if ch in WS:
            i += 1
        elif ch == ord("%"):
            while i < n and data[i] not in b"\r\n":
                i += 1
        elif ch == ord("("):
            s, i = read_string(data, i + 1)
            operands.append(s)
        elif data.startswith(b"<<", i) or data.startswith(b">>", i):
            raise NotImplementedError("inline dictionaries in content streams")
        elif ch == ord("<"):
            j = data.index(b">", i)
            operands.append(bytes.fromhex(re.sub(rb"\s", b"", data[i + 1:j]).decode()))
            i = j + 1
        elif ch == ord("["):
            stack.append(operands)
            operands = []
            i += 1
        elif ch == ord("]"):
            arr, operands = operands, stack.pop()
            operands.append(arr)
            i += 1
        else:
            j = i + 1
            while j < n and data[j] not in WS and data[j] not in DELIMS:
                j += 1
            tok = data[i:j].decode("latin1")
            i = j
            if tok.startswith("/"):
                operands.append(("name", tok[1:]))
            elif re.fullmatch(r"[+-]?(\d+\.?\d*|\.\d+)", tok):
                operands.append(float(tok))
            elif tok in ("true", "false", "null"):
                operands.append(tok)
            else:
                yield tok, operands
                operands = []


# --- fonts ----------------------------------------------------------------------------------------

class Type1CFont:
    """Simple Type1 font with an embedded CFF program (FontFile3 /Type1C)."""

    def __init__(self, doc, xref):
        get = lambda key: doc.xref_get_key(xref, key)
        if get("Subtype")[1] != "/Type1":
            raise NotImplementedError(f"font subtype {get('Subtype')[1]}")
        first = int(get("FirstChar")[1])
        widths = [float(w) for w in get("Widths")[1].strip("[]").split()]
        self.widths = {first + k: w for k, w in enumerate(widths)}

        self.names = {}
        enc_kind, enc = get("Encoding")
        if enc_kind == "xref":
            enc_xref = int(enc.split()[0])
            diffs = re.findall(r"/[^\s/\[\]]+|\d+", doc.xref_get_key(enc_xref, "Differences")[1])
            code = 0
            for tok in diffs:
                if tok.startswith("/"):
                    self.names[code] = tok[1:]
                    code += 1
                else:
                    code = int(tok)

        desc = int(get("FontDescriptor")[1].split()[0])
        ff = int(doc.xref_get_key(desc, "FontFile3")[1].split()[0])
        cff = CFFFontSet()
        cff.decompile(io.BytesIO(doc.xref_stream(ff)), None)
        top = cff[cff.fontNames[0]]
        self.charstrings = top.CharStrings
        self.matrix = tuple(top.FontMatrix)
        if not self.names:  # font's built-in encoding
            self.names = {code: name for code, name in enumerate(top.Encoding) if name != ".notdef"}

    def outline(self, code):
        """Glyph contours in glyph space: list of subpaths of ('M'|'L'|'C'|'Z', points)."""
        pen = RecordingPen()
        self.charstrings[self.names[code]].draw(pen)
        subpaths, cur = [], None
        for op, pts in pen.value:
            if op == "moveTo":
                cur = [("M", pts)]
                subpaths.append(cur)
            elif op == "lineTo":
                cur.append(("L", pts))
            elif op == "curveTo":
                if len(pts) != 3:
                    raise NotImplementedError("super-bezier glyph segments")
                cur.append(("C", pts))
            elif op in ("closePath", "endPath"):
                cur.append(("Z", ()))
            else:
                raise NotImplementedError(f"glyph pen op {op}")
        return subpaths


# --- interpreter ----------------------------------------------------------------------------------

def extract_layers(doc):
    """Returns (artboard size, [(layer name, [(rgb, fill rule, subpaths)])]) in drawing order.

    Subpaths are lists of ('M'|'L'|'C'|'Z', points) in artboard points with y down.
    """
    page = doc[0]
    media = page.mediabox
    height = media.height

    props = {}  # /MCn -> layer name
    ocgs = doc.get_ocgs()
    m = re.search(r"/Properties\s*<<(.*?)>>", doc.xref_object(page.xref, compressed=True), re.S)
    if m:
        for key, xref in re.findall(r"/(\w+)\s*(\d+)\s+0\s+R", m.group(1)):
            if int(xref) in ocgs:
                props[key] = ocgs[int(xref)]["name"]
    fonts = {}
    for xref, _, _, _, ref_name, *_ in page.get_fonts(full=True):
        fonts[ref_name] = Type1CFont(doc, xref)

    def to_art(pt):
        return (pt[0] - media.x0, height - (pt[1] - media.y0))

    layers = {}  # name -> fills; dicts keep first-appearance (z) order
    marked = []  # marked-content stack of layer names (None for non-layer content)
    gstack = []
    ctm, rgb = IDENTITY, (0.0, 0.0, 0.0)
    path, cur = [], None
    tm = tlm = IDENTITY
    font, size, char_space, word_space, hscale, rise, render = None, 1.0, 0.0, 0.0, 1.0, 0.0, 0

    def emit(subpaths, rule):
        layer = next((name for name in reversed(marked) if name), None)
        if layer is None:
            raise ValueError("artwork outside any layer")
        fill = (rgb, rule, subpaths)
        fills = layers.setdefault(layer, [])
        if fill not in fills:  # Illustrator sometimes paints the same shape twice
            fills.append(fill)

    def show(string):
        nonlocal tm
        if render != 0:
            raise NotImplementedError(f"text render mode {render}")
        for code in string:
            trm = mul(mul((size * hscale, 0, 0, size, 0, rise), tm), ctm)
            glyph_m = mul(font.matrix, trm)
            subpaths = [[(op, tuple(to_art(apply(glyph_m, *p)) for p in pts)) for op, pts in sp]
                        for sp in font.outline(code)]
            if subpaths:
                emit(subpaths, "nonzero")
            advance = font.widths[code] / 1000 * size + char_space + (word_space if code == 32 else 0)
            tm = mul((1, 0, 0, 1, advance * hscale, 0), tm)

    ignored = {"gs", "ri", "i", "w", "J", "j", "M", "d", "W", "W*", "ET", "BX", "EX", "MP", "DP"}
    for op, args in tokens(page.read_contents()):
        if op == "q":
            gstack.append((ctm, rgb, font, size, char_space, word_space, hscale, rise, render))
        elif op == "Q":
            ctm, rgb, font, size, char_space, word_space, hscale, rise, render = gstack.pop()
        elif op == "cm":
            ctm = mul(tuple(args), ctm)
        elif op == "rg":
            rgb = tuple(args)
        elif op == "g":
            rgb = (args[0],) * 3
        elif op == "m":
            cur = [("M", (to_art(apply(ctm, *args)),))]
            path.append(cur)
        elif op == "l":
            cur.append(("L", (to_art(apply(ctm, *args)),)))
        elif op in ("c", "v", "y"):
            last = cur[-1][1][-1]
            pts = [to_art(apply(ctm, args[k], args[k + 1])) for k in range(0, len(args), 2)]
            if op == "v":
                pts = [last] + pts
            elif op == "y":
                pts = pts + [pts[-1]]
            cur.append(("C", tuple(pts)))
        elif op == "h":
            cur.append(("Z", ()))
        elif op == "re":
            x, y, w, h = args
            corners = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
            pts = [to_art(apply(ctm, *c)) for c in corners]
            cur = [("M", (pts[0],))] + [("L", (p,)) for p in pts[1:]] + [("Z", ())]
            path.append(cur)
        elif op in ("f", "F", "f*"):
            if path:
                emit(path, "evenodd" if op == "f*" else "nonzero")
            path, cur = [], None
        elif op == "n":  # end of a clip path; clips are dropped so layers keep their full shape
            path, cur = [], None
        elif op == "BT":
            tm = tlm = IDENTITY
        elif op == "Tf":
            font, size = fonts[args[0][1]], args[1]
        elif op == "Tm":
            tm = tlm = tuple(args)
        elif op == "Td":
            tm = tlm = mul((1, 0, 0, 1, args[0], args[1]), tlm)
        elif op == "Tc":
            char_space = args[0]
        elif op == "Tw":
            word_space = args[0]
        elif op == "Tz":
            hscale = args[0] / 100
        elif op == "Ts":
            rise = args[0]
        elif op == "Tr":
            render = int(args[0])
        elif op == "Tj":
            show(args[0])
        elif op == "TJ":
            for item in args[0]:
                if isinstance(item, bytes):
                    show(item)
                else:
                    tm = mul((1, 0, 0, 1, -item / 1000 * size * hscale, 0), tm)
        elif op == "BDC":
            tag, prop = args[0][1], args[1]
            marked.append(props.get(prop[1]) if tag == "OC" and isinstance(prop, tuple) else None)
        elif op == "BMC":
            marked.append(None)
        elif op == "EMC":
            marked.pop()
        elif op not in ignored:
            raise NotImplementedError(f"PDF operator {op!r} (expand strokes/effects in Illustrator)")

    return (media.width, height), list(layers.items())


# --- Swift output ---------------------------------------------------------------------------------

def num(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def point(p):
    return f"CGPoint(x: {num(p[0])}, y: {num(p[1])})"


def swift_fill(rgb, rule, subpaths, indent):
    pad = " " * indent
    lines = [f"{pad}ArtFill(color: Color(red: {num(rgb[0])}, green: {num(rgb[1])}, blue: {num(rgb[2])}), "
             f"evenOdd: {'true' if rule == 'evenodd' else 'false'}, path: Path {{ p in"]
    for sp in subpaths:
        for op, pts in sp:
            if op == "M":
                lines.append(f"{pad}    p.move(to: {point(pts[0])})")
            elif op == "L":
                lines.append(f"{pad}    p.addLine(to: {point(pts[0])})")
            elif op == "C":
                lines.append(f"{pad}    p.addCurve(to: {point(pts[2])}, control1: {point(pts[0])}, "
                             f"control2: {point(pts[1])})")
            elif op == "Z":
                lines.append(f"{pad}    p.closeSubpath()")
    lines.append(f"{pad}}}),")
    return lines


def identifier(name):
    words = re.findall(r"[A-Za-z0-9]+", name) or ["layer"]
    ident = words[0].lower() + "".join(w.capitalize() for w in words[1:])
    return "_" + ident if ident[0].isdigit() else ident


def generate(cfg):
    src = ROOT / cfg["src"]
    doc = fitz.open(src)
    (width, height), layers = extract_layers(doc)
    names, props = cfg["layers"], []
    out = [
        f"// Generated by design/{Path(__file__).name} from design/{cfg['src']}. Do not edit; rerun the script.",
        "",
        "import SwiftUI",
        "",
        f"/// Layers of the {cfg['src']} artboard, bottom to top, in artboard points ({num(width)} × {num(height)}, y down).",
        f"enum {cfg['enum']} {{",
        f"    static let artboard = CGRect(x: 0, y: 0, width: {num(width)}, height: {num(height)})",
    ]
    for layer, fills in layers:
        prop = names.get(layer) or identifier(layer)
        if prop not in names.values():
            print(f"  warning: {cfg['src']}: unnamed layer {layer!r} -> {prop}")
        props.append(prop)
        out += ["", f"    /// Illustrator \"{layer}\".",
                f"    static let {prop} = ArtLayer(name: \"{layer}\", fills: ["]
        for rgb, rule, subpaths in fills:
            out += swift_fill(rgb, rule, subpaths, 8)
        out.append("    ])")
    for layer in names:
        if layer not in dict(layers):
            print(f"  warning: {cfg['src']}: layer {layer!r} is empty or missing")
    out += ["", "    /// Every layer in drawing order.", f"    static let layers = [{', '.join(props)}]", "}", ""]
    dest = OUT_DIR / cfg["out"]
    dest.write_text("\n".join(out))
    print(f"{cfg['src']} -> {dest.relative_to(ROOT.parent)} ({', '.join(props)})")


if __name__ == "__main__":
    for cfg in ARTBOARDS:
        generate(cfg)

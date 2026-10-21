#!/usr/bin/env python3
"""Render a GNM frame capture (PS4_GNM_CAPTURE_FRAME) as one local HTML page.

usage: gnm_capture_view.py <frame_dir> [-o <out.html>] [--thumb <px>]

<frame_dir> is <PS4_GNM_CAPTURE_DIR>/frame_<n> with manifest.json (docs/gnm-capture.md). The page
lists the passes in submission order with the PNG views of their textures after the pass, their
shaders, bindings and state, so the first pass whose output goes wrong can be found by eye.
The page is written into the capture (default <frame_dir>/index.html) and references the PNGs
there by relative path; nothing is written into the repository.
"""
import argparse
import html
import json
import os
import sys


def fmt_hex(v):
    return v if isinstance(v, str) else hex(v)


def pass_summary(p):
    if p["type"] == "draw":
        what = "draw %s n=%d inst=%d" % ("indexed" if p.get("indexed") else "", p.get("count", 0),
                                         p.get("num_instances", 1))
    else:
        d = p.get("dim", [0, 0, 0])
        what = "dispatch %dx%dx%d" % (d[0], d[1], d[2])
    if p.get("indirect_addr", "0x0") not in ("0x0", 0):
        a = p.get("indirect_args", [])
        what += " indirect %s args %s" % (fmt_hex(p["indirect_addr"]), " ".join(str(x) for x in a))
    return what.replace("draw  ", "draw ")


def stage_cell(p):
    rows = []
    for s in p.get("stages", []):
        rows.append("%s %s pgm %s" % (s["stage"], s["code_addr"], s["pgm_hash"]))
    return "<br>".join(html.escape(r) for r in rows)


def bindings_cell(p):
    out = []
    for b in p.get("buffers", []):
        out.append("%s buf%d %s +%d%s" % (b["stage"], b["index"], b["addr"], b["size"], " W" if b.get("written") else ""))
    for i in p.get("images", []):
        src = "gpu" if i.get("textures") else "guest"
        out.append("%s img%d %s %dx%d fmt %d/%d %s%s" % (i["stage"], i["index"], i["addr"], i["width"], i["height"],
                                                        i["dfmt"], i["nfmt"], src, " storage" if i.get("storage") else ""))
    return "<br>".join(html.escape(r) for r in out)


def state_cell(p):
    s = p.get("state", {})
    if p["type"] != "draw" or not s:
        return ""
    blends = [str(i) for i, e in enumerate(s.get("blend_enable", [])) if e]
    vp = s.get("viewport", [0] * 6)
    parts = [
        "blend %s" % (",".join(blends) if blends else "off"),
        "depth %s%s cmp %d" % ("test" if s.get("depth_test") else "off", " write" if s.get("depth_write") else "",
                               s.get("depth_compare", 0)),
        "stencil %s" % ("on" if s.get("stencil_test") else "off"),
        "vp %g,%g %gx%g" % (vp[0], vp[1], vp[2], vp[3]),
    ]
    return "<br>".join(html.escape(x) for x in parts)


def textures_cell(p, thumb):
    out = []
    for t in p.get("textures", []):
        idd = t.get("id", {})
        label = "%s %s %dx%d f%d%s" % (t["role"], idd.get("address", "?"), idd.get("mtl_width", 0),
                                       idd.get("mtl_height", 0), idd.get("mtl_format", 0),
                                       " (written)" if t.get("written") else "")
        if t.get("png_file"):
            out.append('<figure><a href="%s"><img src="%s" width="%d" loading="lazy"></a><figcaption>%s<br>%s'
                       '</figcaption></figure>' % (html.escape(t["png_file"]), html.escape(t["png_file"]), thumb,
                                                   html.escape(label), html.escape(t.get("png_mode", ""))))
        else:
            why = t.get("readback") or t.get("png_mode") or "no view"
            out.append('<figure class="none"><figcaption>%s<br>%s</figcaption></figure>' % (html.escape(label),
                                                                                           html.escape(why)))
    return "".join(out)


def render(frame, thumb):
    passes = frame.get("passes", [])
    n_draw = sum(1 for p in passes if p["type"] == "draw")
    n_disp = len(passes) - n_draw
    n_skip = sum(1 for p in passes if p.get("skipped"))
    rows = []
    for p in passes:
        cls = ' class="skipped"' if p.get("skipped") else ""
        name = p.get("name", "")
        if p.get("skipped"):
            name += " [skipped: %s]" % p["skipped"]
        rows.append(
            '<tr id="p%d"%s><td><a href="#p%d">%d</a></td><td>%s<br>%s</td><td>%s</td><td>%s</td><td>%s</td>'
            '<td>%s</td><td>%d in / %d out</td></tr>' %
            (p["index"], cls, p["index"], p["index"], html.escape(name), html.escape(pass_summary(p)), stage_cell(p),
             textures_cell(p, thumb), bindings_cell(p), state_cell(p), len(p.get("inputs", [])),
             len(p.get("outputs", []))))
    head = ("<!doctype html><meta charset='utf-8'><title>GNM capture frame %d</title>"
            "<style>body{font:12px monospace;margin:8px}table{border-collapse:collapse}"
            "td{border:1px solid #999;padding:3px;vertical-align:top}tr.skipped{background:#fdd}"
            "figure{display:inline-block;margin:2px}figure.none{width:%dpx;height:40px;background:#eee}"
            "img{image-rendering:pixelated;border:1px solid #444}</style>" % (frame.get("frame", 0), thumb))
    summary = ("<h1>Frame %d</h1><p>%d passes: %d draws, %d dispatches, %d skipped. mem_size %s, neo %s, gcn %s</p>" %
               (frame.get("frame", 0), len(passes), n_draw, n_disp, n_skip, html.escape(str(frame.get("mem_size"))),
                html.escape(str(frame.get("neo"))), html.escape(str(frame.get("gcn_cache_id", "")))))
    table = ("<table><tr><th>#</th><th>pass</th><th>shaders</th><th>textures after the pass</th><th>bindings</th>"
             "<th>state</th><th>guest ranges</th></tr>%s</table>" % "\n".join(rows))
    return head + summary + table + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("frame_dir")
    ap.add_argument("-o", "--out")
    ap.add_argument("--thumb", type=int, default=160)
    a = ap.parse_args(argv)
    manifest = os.path.join(a.frame_dir, "manifest.json")
    try:
        with open(manifest, encoding="utf-8") as f:
            frame = json.load(f)
    except (OSError, ValueError) as e:
        print("gnm_capture_view: cannot read %s: %s" % (manifest, e), file=sys.stderr)
        return 2
    if frame.get("version") != 1:
        print("gnm_capture_view: manifest version %r, expected 1" % frame.get("version"), file=sys.stderr)
        return 2
    out = a.out or os.path.join(a.frame_dir, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(frame, a.thumb))
    print("gnm_capture_view: %d passes -> %s" % (len(frame.get("passes", [])), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())

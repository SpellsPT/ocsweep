#!/usr/bin/env python3
"""Build card1-memory-sweep.html: the 2026-09-26 memory sweep of hermespt's three RTX 4070s.
Chart 1 = measured bandwidth per offset; chart 2 = share of the card's own ideal gain (roll-off)."""
import csv, html, os

RUNS = os.path.expanduser("~/ocsweep/data/runs")
OUT = os.path.expanduser("~/ocsweep/charts/card1-memory-sweep.html")
CARDS = [("f766172e", "Card 1", "var(--s1)", "errors at +3850 (gpu_burn)"),
         ("9b984f20", "Card 0", "var(--s2)", "errors at +2950 (552 memory mismatches)"),
         ("d04bc082", "Card 3", "var(--s3)", "plateau flagged at +2950")]

data = {}
for uid, name, col, _ in CARDS:
    rows = [r for r in csv.reader(open(f"{RUNS}/{uid}-steps.csv")) if r and r[1] == "mem"]
    pts = [(int(r[2]), int(r[3]), float(r[4]), r[12]) for r in rows]
    st = [p for p in pts if p[0] == 0][0]
    a = [p for p in pts if p[0] == 2000][0]
    rate = (a[2] - st[2]) / (a[1] - st[1])          # GB/s per real MHz, stock -> +2000
    data[uid] = dict(pts=pts, st=st, rate=rate,
                     eff=[(o, clk, 100 * (b - st[2]) / (rate * (clk - st[1])), res) for o, clk, b, res in pts if o >= 2000])

W, H, L, R, T, B = 920, 480, 70, 150, 30, 60
x0, x1 = 1950, 3900
X = lambda o: L + (o - x0) / (x1 - x0) * (W - L - R)

def chart(series_key, y0, y1, ystep, yfmt, ylab, label_dy, extra=""):
    Y = lambda v: T + (y1 - v) / (y1 - y0) * (H - T - B)
    s = []
    v = y0
    while v <= y1 + 1e-9:
        s.append(f'<line x1="{L}" x2="{W-R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" class="grid"/>'
                 f'<text x="{L-8}" y="{Y(v)+4:.1f}" class="ax" text-anchor="end">{yfmt(v)}</text>')
        v += ystep
    for xv in range(2000, 3901, 200):
        s.append(f'<text x="{X(xv):.1f}" y="{H-B+20}" class="ax" text-anchor="middle">+{xv}</text>')
    s.append(f'<text x="{(L+W-R)/2}" y="{H-12}" class="lab" text-anchor="middle">Memory offset (NVML, transfer-rate MHz; Afterburner shows half)</text>')
    s.append(f'<text x="18" y="{(T+H-B)/2}" class="lab" text-anchor="middle" transform="rotate(-90 18 {(T+H-B)/2})">{ylab}</text>')
    s.append(extra(Y) if extra else "")
    for uid, name, col, _ in CARDS:
        pts = series_key(data[uid])
        ok = [p for p in pts if p[3] == "PASS"]
        s.append('<polyline fill="none" stroke="%s" stroke-width="2" points="%s"/>' % (
            col, " ".join(f"{X(o):.1f},{Y(v):.1f}" for o, _, v, _ in ok)))
        for o, clk, v, res in pts:
            tip = html.escape(f"{name}  +{o}  ({clk} MHz)  {yfmt(v, True)}  {res}")
            xx, yy = X(o), Y(v)
            if res == "PASS":
                s.append(f'<circle cx="{xx:.1f}" cy="{yy:.1f}" r="4" fill="{col}" class="pt"><title>{tip}</title></circle>')
            else:
                s.append(f'<g><title>{tip}</title><circle cx="{xx:.1f}" cy="{yy:.1f}" r="7" fill="var(--bg)" stroke="{col}" stroke-width="2"/>'
                         f'<path d="M{xx-4:.1f},{yy-4:.1f}L{xx+4:.1f},{yy+4:.1f}M{xx+4:.1f},{yy-4:.1f}L{xx-4:.1f},{yy+4:.1f}" stroke="{col}" stroke-width="2"/></g>')
        lo, _, lv, _ = ok[-1]
        dx, dy = label_dy[name]
        s.append(f'<text x="{X(lo)+dx:.1f}" y="{Y(lv)+dy:.1f}" class="dl">{name}</text>')
    return f'<svg viewBox="0 0 {W} {H}" role="img">{"".join(s)}</svg>'

def ideal_line(Y):
    d = data["f766172e"]; st = d["st"]
    pts = [(o, st[2] + d["rate"] * ((10501 + o / 2) - st[1])) for o in (2000, 3850)]
    return (f'<line x1="{X(pts[0][0]):.1f}" y1="{Y(pts[0][1]):.1f}" x2="{X(pts[1][0]):.1f}" y2="{Y(pts[1][1]):.1f}" class="ideal"/>'
            f'<text x="{X(3850)+6:.1f}" y="{Y(pts[1][1])+4:.1f}" class="dl" style="fill:var(--t2)">perfect scaling</text>')

def hundred_line(Y):
    return (f'<line x1="{L}" x2="{W-R}" y1="{Y(100):.1f}" y2="{Y(100):.1f}" class="ideal"/>'
            f'<text x="{W-R+6}" y="{Y(100)+4:.1f}" class="dl" style="fill:var(--t2)">perfect scaling</text>')

bw = chart(lambda d: [p for p in d["pts"] if p[0] >= 2000], 495, 545, 10,
           lambda v, t=False: f"{v:.2f} GB/s" if t else f"{v:.0f}", "Measured bandwidth (GB/s)",
           {"Card 1": (14, 14), "Card 0": (-38, -16), "Card 3": (-40, 22)}, ideal_line)
ef = chart(lambda d: d["eff"], 93, 103, 1,
           lambda v, t=False: f"{v:.1f} % of ideal" if t else f"{v:.0f}%", "Share of the card's ideal gain",
           {"Card 1": (14, 14), "Card 0": (12, -12), "Card 3": (12, 18)}, hundred_line)

legend = "".join(f'<span><span class="sw" style="background:{c}"></span>{n}: {why}</span>' for _, n, c, why in CARDS)
tables = ""
for uid, name, _, _ in CARDS:
    d = data[uid]
    rows = "".join(f"<tr><td>+{o}</td><td>{clk}</td><td>{b:.2f}</td><td>{e:.1f}%</td><td>{res}</td></tr>"
                   for (o, clk, b, res), (_, _, e, _) in zip([p for p in d["pts"] if p[0] >= 2000], d["eff"]))
    tables += (f'<details><summary>{name} table (stock {d["st"][2]:.1f} GB/s at {d["st"][1]} MHz)</summary><div class="tw"><table>'
               f"<tr><th>Offset</th><th>Clock MHz</th><th>GB/s</th><th>Of ideal</th><th>Result</th></tr>{rows}</table></div></details>")

page = f'''<title>4070 Memory Sweep</title><style>
:root{{--bg:#fcfcfb;--t1:#0b0b0b;--t2:#52514e;--grid:#e6e5e1;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#1a1a19;--t1:#fff;--t2:#c3c2b7;--grid:#383835;--s1:#3987e5;--s2:#d95926;--s3:#199e70;color-scheme:dark}}}}
:root[data-theme="dark"]{{--bg:#1a1a19;--t1:#fff;--t2:#c3c2b7;--grid:#383835;--s1:#3987e5;--s2:#d95926;--s3:#199e70;color-scheme:dark}}
body{{background:var(--bg);color:var(--t1);font:15px/1.5 system-ui,sans-serif;margin:0}}
main{{padding-block:24px;padding-inline:16px;max-width:980px;margin-inline:auto}}
h1{{font-size:22px;margin:0 0 4px;text-wrap:balance}} h2{{font-size:17px;margin:28px 0 2px}} p{{color:var(--t2);margin:4px 0 12px;max-width:70ch}}
svg{{width:100%;height:auto;display:block}}
.grid{{stroke:var(--grid);stroke-width:1}} .ax{{fill:var(--t2);font-size:12px}} .lab{{fill:var(--t2);font-size:13px}} .dl{{fill:var(--t1);font-size:13px;font-weight:600}}
.ideal{{stroke:var(--t2);stroke-width:1.5;stroke-dasharray:6 5}} .pt:hover{{r:7}}
.legend{{display:flex;gap:8px 18px;flex-wrap:wrap;font-size:13px;color:var(--t2);margin:6px 0}} .sw{{display:inline-block;width:12px;height:12px;border-radius:3px;vertical-align:-1px;margin-right:6px}}
details{{margin-top:10px}} .tw{{overflow-x:auto}} table{{border-collapse:collapse;font-size:13px;margin-top:8px;font-variant-numeric:tabular-nums}} td,th{{padding:3px 12px;border-bottom:1px solid var(--grid);text-align:right}}
</style><main>
<h1>RTX 4070 memory sweep, hermespt</h1>
<p>Night of 2026-09-25/26. Core at +0 for every point. Each card's stock (+0) bandwidth is about 458 GB/s at 10,501 MHz, off the left edge. ✕ marks the step that failed. Hover a point for its numbers.</p>
<div class="legend">{legend}<span><span class="sw" style="background:transparent;border:1.5px dashed var(--t2)"></span>Perfect scaling</span></div>
<h2>Bandwidth</h2>
<p>All three cards give almost the same bandwidth at the same offset. They differ in how far they get before errors. The dashed line is card 1's own stock→+2000 rate carried on.</p>
{bw}
<h2>Roll-off: share of the ideal gain</h2>
<p>Bandwidth gained since stock, divided by what the card's own stock→+2000 rate predicts for that clock. 100% means the extra clock is all real speed; a falling line means the memory is starting to retry transfers (EDC). The RTX 3090 is not shown: its sweep stopped at stock on a memory-temperature limit.</p>
{ef}
{tables}
</main>'''
open(OUT, "w").write(page)
print("written", OUT)

package main

// Minimal standard-library SVG line charts.

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

type series struct {
	name   string
	color  string
	dash   string
	xs, ys []float64
}

// chart draws one panel into b at offset (ox, oy) with size w x h.
// X is log2 of the ring size. If logY is set the Y axis is logarithmic.
func chart(b *strings.Builder, ox, oy, w, h float64, title, ylabel string, ss []series, logY bool) {
	const ml, mr, mt, mb = 56.0, 12.0, 30.0, 40.0
	pw, ph := w-ml-mr, h-mt-mb
	xmin, xmax := math.Inf(1), math.Inf(-1)
	ymin, ymax := math.Inf(1), math.Inf(-1)
	for _, s := range ss {
		for i := range s.xs {
			xmin, xmax = math.Min(xmin, s.xs[i]), math.Max(xmax, s.xs[i])
			ymin, ymax = math.Min(ymin, s.ys[i]), math.Max(ymax, s.ys[i])
		}
	}
	ty := func(v float64) float64 {
		if logY {
			return math.Log2(v)
		}
		return v
	}
	var lo, hi float64
	if logY {
		lo, hi = math.Floor(ty(ymin)), math.Ceil(ty(ymax))
	} else {
		lo, hi = 0, niceCeil(ymax)
	}
	px := func(x float64) float64 { return ox + ml + (x-xmin)/(xmax-xmin)*pw }
	py := func(y float64) float64 { return oy + mt + ph - (ty(y)-lo)/(hi-lo)*ph }

	fmt.Fprintf(b, `<text x="%.0f" y="%.0f" class="t">%s</text>`+"\n", ox+ml, oy+16, title)
	// y grid
	if logY {
		for e := lo; e <= hi; e++ {
			v := math.Pow(2, e)
			y := py(v)
			fmt.Fprintf(b, `<line x1="%.1f" x2="%.1f" y1="%.1f" y2="%.1f" class="g"/><text x="%.1f" y="%.1f" class="a" text-anchor="end">%g</text>`+"\n",
				ox+ml, ox+ml+pw, y, y, ox+ml-6, y+4, v)
		}
	} else {
		step := niceStep(hi / 5)
		for v := 0.0; v <= hi+1e-9; v += step {
			y := py(v)
			fmt.Fprintf(b, `<line x1="%.1f" x2="%.1f" y1="%.1f" y2="%.1f" class="g"/><text x="%.1f" y="%.1f" class="a" text-anchor="end">%g</text>`+"\n",
				ox+ml, ox+ml+pw, y, y, ox+ml-6, y+4, v)
		}
	}
	for x := math.Ceil(xmin); x <= xmax+1e-9; x += 2 {
		fmt.Fprintf(b, `<text x="%.1f" y="%.1f" class="a" text-anchor="middle">%g</text>`+"\n", px(x), oy+mt+ph+16, x)
	}
	fmt.Fprintf(b, `<text x="%.1f" y="%.1f" class="a" text-anchor="middle">log2 N (number of nodes = 2^x)</text>`+"\n", ox+ml+pw/2, oy+h-4)
	fmt.Fprintf(b, `<text transform="translate(%.1f %.1f) rotate(-90)" class="a" text-anchor="middle">%s</text>`+"\n", ox+12, oy+mt+ph/2, ylabel)
	for _, s := range ss {
		var pts []string
		for i := range s.xs {
			pts = append(pts, fmt.Sprintf("%.1f,%.1f", px(s.xs[i]), py(s.ys[i])))
		}
		fmt.Fprintf(b, `<polyline fill="none" stroke="%s" stroke-width="2" %s points="%s"/>`+"\n", s.color, s.dash, strings.Join(pts, " "))
		for i := range s.xs {
			fmt.Fprintf(b, `<circle cx="%.1f" cy="%.1f" r="2.5" fill="%s"/>`+"\n", px(s.xs[i]), py(s.ys[i]), s.color)
		}
	}
}

func niceStep(v float64) float64 {
	p := math.Pow(10, math.Floor(math.Log10(v)))
	for _, m := range []float64{1, 2, 5, 10} {
		if m*p >= v {
			return m * p
		}
	}
	return 10 * p
}

func niceCeil(v float64) float64 {
	s := niceStep(v / 5)
	return math.Ceil(v/s) * s
}

const svgHead = `<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Helvetica, Arial, sans-serif">
<style>.t{font-size:13px;font-weight:bold;fill:#222}.a{font-size:11px;fill:#444}.g{stroke:#ddd;stroke-width:1}.l{font-size:11px;fill:#222}</style>
<rect width="100%%" height="100%%" fill="white"/>
`

// colour per variant (colour-blind-safe palette)
var variantStyle = map[string][2]string{
	"chord":       {"#000000", ""},
	"koorde-k2":   {"#0072B2", ""},
	"koorde-k4":   {"#E69F00", ""},
	"koorde-k8":   {"#009E73", ""},
	"koorde-k16":  {"#CC79A7", ""},
	"koorde-klog": {"#D55E00", `stroke-dasharray="5 3"`},
}

func collect(pts []Point, mode WindowMode, f func(Point) float64) []series {
	by := map[string]*series{}
	for _, p := range pts {
		if p.Window != mode && !(p.Protocol == "chord" && mode == WindowRealistic) {
			continue
		}
		name := p.Variant
		st := variantStyle[name]
		s := by[name]
		if s == nil {
			s = &series{name: name, color: st[0], dash: st[1]}
			by[name] = s
		}
		s.xs = append(s.xs, math.Log2(float64(p.N)))
		s.ys = append(s.ys, f(p))
	}
	var out []series
	for _, s := range by {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
}

func legend(b *strings.Builder, x, y float64, ss []series) {
	for i, s := range ss {
		yy := y + float64(i)*16
		fmt.Fprintf(b, `<line x1="%.0f" x2="%.0f" y1="%.0f" y2="%.0f" stroke="%s" stroke-width="2" %s/><text x="%.0f" y="%.0f" class="l">%s</text>`+"\n",
			x, x+22, yy, yy, s.color, s.dash, x+28, yy+4, labelOf(s.name))
	}
}

func labelOf(v string) string {
	switch v {
	case "chord":
		return "Chord"
	case "koorde-klog":
		return "Koorde, k = nearest power of 2 to log2 N"
	}
	return "Koorde, k=" + strings.TrimPrefix(v, "koorde-k")
}

// hopsSVG: left panel RPC hops, right panel logical steps (mean, realistic tables).
func hopsSVG(pts []Point) string {
	var b strings.Builder
	W, H := 980.0, 400.0
	fmt.Fprintf(&b, svgHead, int(W), int(H), int(W), int(H))
	rpc := collect(pts, WindowRealistic, func(p Point) float64 { return p.RPC.Mean })
	stp := collect(pts, WindowRealistic, func(p Point) float64 { return p.Steps.Mean })
	chart(&b, 0, 0, 440, 340, "Mean RPC hops per lookup (network hops)", "mean RPC hops (log scale)", rpc, true)
	chart(&b, 460, 0, 440, 340, "Mean logical routing steps (incl. local de Bruijn steps)", "mean logical steps (log scale)", stp, true)
	legend(&b, 60, 356, rpc[:3])
	legend(&b, 330, 356, rpc[3:])
	b.WriteString("</svg>\n")
	return b.String()
}

// stateSVG: distinct neighbours per node against N.
func stateSVG(pts []Point) string {
	var b strings.Builder
	W, H := 520.0, 400.0
	fmt.Fprintf(&b, svgHead, int(W), int(H), int(W), int(H))
	ss := collect(pts, WindowRealistic, func(p Point) float64 { return p.StateDist })
	chart(&b, 0, 0, 500, 340, "State per node (distinct other nodes held)", "distinct neighbours per node", ss, false)
	legend(&b, 60, 356, ss[:3])
	legend(&b, 280, 356, ss[3:])
	b.WriteString("</svg>\n")
	return b.String()
}

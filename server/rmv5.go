package main

// Renders reMarkable .lines files version 3 and 5 (older notebooks) to SVG;
// rmc reads only version 6. Layout (little endian, after a 43-byte header):
// int32 layers; per layer int32 strokes; per stroke int32 pen, int32 colour,
// int32 unused, float32 width, [v5: int32 unused], int32 points; per point
// float32 x, y, speed, direction, width, pressure.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
)

const (
	v5Width  = 1404
	v5Height = 1872
)

func lineVersion(header []byte) int {
	switch {
	case bytes.HasPrefix(header, []byte("reMarkable .lines file, version=6")):
		return 6
	case bytes.HasPrefix(header, []byte("reMarkable .lines file, version=5")):
		return 5
	case bytes.HasPrefix(header, []byte("reMarkable .lines file, version=3")):
		return 3
	}
	return 0
}

func renderOld(rm, svg string, version int) error {
	data, err := os.ReadFile(rm)
	if err != nil {
		return err
	}
	if len(data) < 43 {
		return errors.New("short file")
	}
	r := bytes.NewReader(data[43:])
	i32 := func() (int32, error) { var v int32; err := binary.Read(r, binary.LittleEndian, &v); return v, err }
	f32 := func() (float32, error) { var v float32; err := binary.Read(r, binary.LittleEndian, &v); return v, err }

	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">`, v5Width, v5Height, v5Width, v5Height)
	b.WriteString(`<rect width="100%" height="100%" fill="white"/>`)
	layers, err := i32()
	if err != nil {
		return err
	}
	for l := int32(0); l < layers; l++ {
		strokes, err := i32()
		if err != nil {
			return err
		}
		for s := int32(0); s < strokes; s++ {
			pen, _ := i32()
			colour, _ := i32()
			i32()
			width, _ := f32()
			if version == 5 {
				i32()
			}
			n, err := i32()
			if err != nil {
				return err
			}
			if n < 0 || int(n)*24 > r.Len() {
				return fmt.Errorf("bad point count %d", n)
			}
			pts := make([][6]float32, n)
			if err := binary.Read(r, binary.LittleEndian, pts); err != nil {
				return err
			}
			stroke(&b, pen, colour, width, pts)
		}
	}
	if r.Len() > 0 && r.Len() < 4 {
		return io.ErrUnexpectedEOF
	}
	b.WriteString("</svg>")
	return os.WriteFile(svg, []byte(b.String()), 0o640)
}

func stroke(b *strings.Builder, pen, colour int32, width float32, pts [][6]float32) {
	if len(pts) == 0 || pen == 8 { // 8: erase-area selections
		return
	}
	col := map[int32]string{0: "black", 1: "#808080", 2: "white"}[colour]
	if col == "" {
		col = "#404040"
	}
	opacity := 1.0
	switch pen {
	case 6: // eraser
		col = "white"
	case 5, 18: // highlighters
		col, opacity = "#b0b0b0", 0.4
	}
	w := 0.0
	for _, p := range pts {
		w += float64(p[4])
	}
	w /= float64(len(pts))
	if w <= 0 || math.IsNaN(w) {
		w = float64(width)
	}
	if w < 1 {
		w = 1
	}
	fmt.Fprintf(b, `<polyline fill="none" stroke="%s" stroke-opacity="%.2f" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round" points="`, col, opacity, w)
	for _, p := range pts {
		fmt.Fprintf(b, "%.1f,%.1f ", p[0], p[1])
	}
	b.WriteString(`"/>`)
}

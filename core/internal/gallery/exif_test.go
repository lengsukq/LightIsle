package gallery

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"testing"
	"time"
)

// The EXIF fixtures below are synthesized in-test (a TIFF IFD tree wrapped in
// a JPEG APP1 segment) so the suite never ships binary media assets.

type exifEntry struct {
	tag   uint16
	typ   uint16
	count uint32
	data  []byte
}

func asciiEntry(tag uint16, value string) exifEntry {
	return exifEntry{tag, 2, uint32(len(value) + 1), append([]byte(value), 0)}
}

func shortEntry(tag uint16, value uint16) exifEntry {
	return exifEntry{tag, 3, 1, []byte{byte(value), byte(value >> 8)}}
}

func rationalsEntry(tag uint16, pairs ...uint32) exifEntry {
	var data []byte
	for _, value := range pairs {
		data = binary.LittleEndian.AppendUint32(data, value)
	}
	return exifEntry{tag, 5, uint32(len(pairs) / 2), data}
}

// buildEXIF lays out IFD0 plus the Exif and GPS sub-IFDs in little-endian
// TIFF order and wires the pointer tags automatically. The pointer entries
// join IFD0 before offsets are computed so the layout stays consistent.
func buildEXIF(ifd0, exifIFD, gpsIFD []exifEntry) []byte {
	ifd0 = append(append([]exifEntry(nil), ifd0...), exifEntry{}, exifEntry{})
	offsets := make([]int, 3)
	size := 8
	for i, entries := range [][]exifEntry{ifd0, exifIFD, gpsIFD} {
		offsets[i] = size
		size += 2 + 12*len(entries) + 4
	}
	ifd0[len(ifd0)-2] = exifEntry{0x8769, 4, 1, binary.LittleEndian.AppendUint32(nil, uint32(offsets[1]))}
	ifd0[len(ifd0)-1] = exifEntry{0x8825, 4, 1, binary.LittleEndian.AppendUint32(nil, uint32(offsets[2]))}
	var out bytes.Buffer
	var data bytes.Buffer
	out.WriteString("II")
	binary.Write(&out, binary.LittleEndian, uint16(42))
	binary.Write(&out, binary.LittleEndian, uint32(8))
	dataStart := size
	for i, entries := range [][]exifEntry{ifd0, exifIFD, gpsIFD} {
		binary.Write(&out, binary.LittleEndian, uint16(len(entries)))
		for _, entry := range entries {
			var header [8]byte
			binary.LittleEndian.PutUint16(header[0:2], entry.tag)
			binary.LittleEndian.PutUint16(header[2:4], entry.typ)
			binary.LittleEndian.PutUint32(header[4:8], entry.count)
			out.Write(header[:])
			if len(entry.data) <= 4 {
				fixed := make([]byte, 4)
				copy(fixed, entry.data)
				out.Write(fixed)
			} else {
				binary.Write(&out, binary.LittleEndian, uint32(dataStart+data.Len()))
				data.Write(entry.data)
			}
		}
		next := uint32(0)
		if i < 2 {
			next = uint32(offsets[i+1])
		}
		binary.Write(&out, binary.LittleEndian, next)
	}
	out.Write(data.Bytes())
	return out.Bytes()
}

func jpegWithEXIF(tiff []byte) []byte {
	segment := append([]byte("Exif\x00\x00"), tiff...)
	out := []byte{0xFF, 0xD8, 0xFF, 0xE1}
	out = binary.BigEndian.AppendUint16(out, uint16(len(segment)+2))
	out = append(out, segment...)
	return append(out, 0xFF, 0xD9)
}

func fixtureEXIF() []byte {
	ifd0 := []exifEntry{
		asciiEntry(0x010F, "Fixture Camera"),
		asciiEntry(0x0110, "Fixture One"),
		asciiEntry(0x0132, "2024:03:04 05:06:07"),
	}
	exifIFD := []exifEntry{
		rationalsEntry(0x829A, 1, 250),            // ExposureTime 1/250s
		rationalsEntry(0x829D, 28, 10),            // FNumber f/2.8
		shortEntry(0x8827, 200),                   // ISO
		asciiEntry(0x9003, "2024:03:04 05:06:07"), // DateTimeOriginal
		rationalsEntry(0x920A, 23, 1),             // FocalLength 23mm
		asciiEntry(0xA434, "Fixture Lens 23mm"),   // LensModel
	}
	// 31°13'49.44"N 121°28'25.32"E = (31.2304, 121.4737)
	gpsIFD := []exifEntry{
		asciiEntry(0x0001, "N"),
		rationalsEntry(0x0002, 31, 1, 13, 1, 4944, 100),
		asciiEntry(0x0003, "E"),
		rationalsEntry(0x0004, 121, 1, 28, 1, 2532, 100),
	}
	return buildEXIF(ifd0, exifIFD, gpsIFD)
}

func TestDecodeCaptureExifExtractsLocationAndCamera(t *testing.T) {
	fixture := jpegWithEXIF(fixtureEXIF())
	path := t.TempDir() + "/photo.jpg"
	if err := writeFileForTest(path, fixture); err != nil {
		t.Fatal(err)
	}
	info, ok := decodeCaptureExif(path, testFileReader(t))
	if !ok {
		t.Fatal("fixture EXIF did not decode")
	}
	if !info.HasLocation {
		t.Fatalf("location missing: %+v", info)
	}
	if diff(info.Latitude, 31.2304) || diff(info.Longitude, 121.4737) {
		t.Fatalf("coordinates = (%.6f, %.6f), want (31.2304, 121.4737)", info.Latitude, info.Longitude)
	}
	if !info.HasTime || !info.CapturedAt.Equal(time.Date(2024, 3, 4, 5, 6, 7, 0, time.Local)) {
		t.Fatalf("captured time = %+v", info.CapturedAt)
	}
	if info.CameraMake != "Fixture Camera" || info.CameraModel != "Fixture One" || info.LensModel != "Fixture Lens 23mm" {
		t.Fatalf("camera fields = %+v", info)
	}
	if info.ISO != 200 || diff(info.FNumber, 2.8) || diff(info.ExposureSecs, 0.004) || diff(info.FocalLength, 23) {
		t.Fatalf("exposure fields = %+v", info)
	}
}

func TestDecodeCaptureExifRejectsNullIslandAndSouthWestSigns(t *testing.T) {
	nullIsland := jpegWithEXIF(buildEXIF(nil, nil, []exifEntry{
		asciiEntry(0x0001, "N"),
		rationalsEntry(0x0002, 0, 1, 0, 1, 0, 1),
		asciiEntry(0x0003, "E"),
		rationalsEntry(0x0004, 0, 1, 0, 1, 0, 1),
	}))
	path := t.TempDir() + "/null.jpg"
	if err := writeFileForTest(path, nullIsland); err != nil {
		t.Fatal(err)
	}
	if info, ok := decodeCaptureExif(path, testFileReader(t)); !ok || info.HasLocation {
		t.Fatalf("null island accepted: %+v ok=%v", info, ok)
	}

	southWest := jpegWithEXIF(buildEXIF(nil, nil, []exifEntry{
		asciiEntry(0x0001, "S"),
		rationalsEntry(0x0002, 31, 1, 13, 1, 4944, 100),
		asciiEntry(0x0003, "W"),
		rationalsEntry(0x0004, 121, 1, 28, 1, 2532, 100),
	}))
	path = t.TempDir() + "/southwest.jpg"
	if err := writeFileForTest(path, southWest); err != nil {
		t.Fatal(err)
	}
	info, ok := decodeCaptureExif(path, testFileReader(t))
	if !ok || !info.HasLocation {
		t.Fatalf("southwest location missing: %+v", info)
	}
	if info.Latitude >= 0 || info.Longitude >= 0 {
		t.Fatalf("hemisphere signs lost: (%.4f, %.4f)", info.Latitude, info.Longitude)
	}
}

func TestDecodeCaptureExifSkipsUndecodableFormats(t *testing.T) {
	if _, ok := decodeCaptureExif("photo.png", testFileReader(t)); ok {
		t.Fatal("png should not reach the in-process decoder")
	}
}

func diff(value, want float64) bool {
	const epsilon = 1e-6
	return value < want-epsilon || value > want+epsilon
}

func writeFileForTest(path string, data []byte) error {
	return os.WriteFile(path, data, 0600)
}

func testFileReader(t *testing.T) func(string) (io.ReadCloser, error) {
	t.Helper()
	return func(p string) (io.ReadCloser, error) {
		return os.Open(p)
	}
}

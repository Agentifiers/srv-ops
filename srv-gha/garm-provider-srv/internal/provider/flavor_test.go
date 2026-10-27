package provider

import (
	"slices"
	"testing"
)

func TestParseFlavor(t *testing.T) {
	f, err := ParseFlavor("8c-16g-60g")
	if err != nil {
		t.Fatal(err)
	}
	if f != (Flavor{CPUs: 8, RAMGiB: 16, DiskGiB: 60}) {
		t.Fatalf("got %+v", f)
	}
	wantArgs := []string{"--cpus", "8", "--ram", "16G", "--rootfs-size", "60G"}
	if got := f.SrvArgs(); !slices.Equal(got, wantArgs) {
		t.Fatalf("SrvArgs = %v, want %v", got, wantArgs)
	}
	if f.String() != "8c-16g-60g" {
		t.Fatalf("String = %q", f.String())
	}
}

func TestParseFlavorInvalid(t *testing.T) {
	for _, s := range []string{
		"", "8c-16g", "8c-16g-60", "8-16-60", "8c-16G-60g", "0c-16g-60g",
		"8c-0g-60g", "8c-16g-0g", "-8c-16g-60g", "8c-16g-60g ", "c-16g-60g",
		"99999999999999999999c-1g-1g", "m5.large",
	} {
		if f, err := ParseFlavor(s); err == nil {
			t.Errorf("ParseFlavor(%q) = %+v, want error", s, f)
		}
	}
}

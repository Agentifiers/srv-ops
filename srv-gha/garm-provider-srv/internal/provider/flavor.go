package provider

import (
	"fmt"
	"regexp"
	"strconv"
)

var flavorRE = regexp.MustCompile(`^([0-9]+)c-([0-9]+)g-([0-9]+)g$`)

// Flavor is a parsed pool flavor of the form <cpus>c-<ram>g-<disk>g.
type Flavor struct {
	CPUs    int
	RAMGiB  int
	DiskGiB int
}

// ParseFlavor parses strings such as "8c-16g-60g".
func ParseFlavor(s string) (Flavor, error) {
	m := flavorRE.FindStringSubmatch(s)
	if m == nil {
		return Flavor{}, fmt.Errorf("invalid flavor %q: want <cpus>c-<ram>g-<disk>g, e.g. 8c-16g-60g", s)
	}
	var vals [3]int
	for i, field := range []string{"cpus", "ram", "disk"} {
		v, err := strconv.Atoi(m[i+1])
		if err != nil || v <= 0 {
			return Flavor{}, fmt.Errorf("invalid flavor %q: %s must be a positive integer", s, field)
		}
		vals[i] = v
	}
	return Flavor{CPUs: vals[0], RAMGiB: vals[1], DiskGiB: vals[2]}, nil
}

// SrvArgs returns the sizing arguments for `srv new`.
func (f Flavor) SrvArgs() []string {
	return []string{
		"--cpus", strconv.Itoa(f.CPUs),
		"--ram", strconv.Itoa(f.RAMGiB) + "G",
		"--rootfs-size", strconv.Itoa(f.DiskGiB) + "G",
	}
}

func (f Flavor) String() string {
	return fmt.Sprintf("%dc-%dg-%dg", f.CPUs, f.RAMGiB, f.DiskGiB)
}

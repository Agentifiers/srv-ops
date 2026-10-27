package provider

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
)

const providerIDPrefix = "gha-"

var (
	// srvNameRE is the name contract srv enforces for instances and images.
	srvNameRE    = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	providerIDRE = regexp.MustCompile(`^gha-[0-9a-f]{16}$`)
)

// ProviderID derives the srv instance name for a GARM runner name. GARM names
// are mixed case, which srv rejects, so the name is hashed.
func ProviderID(garmName string) string {
	sum := sha256.Sum256([]byte(garmName))
	return providerIDPrefix + hex.EncodeToString(sum[:8])
}

// IsProviderID reports whether s has the shape of an ID minted by ProviderID.
func IsProviderID(s string) bool {
	return providerIDRE.MatchString(s)
}

// ResolveID maps GARM_INSTANCE_ID, which GARM sets to either the provider ID
// or the runner name, to the srv instance name. The result always carries the
// gha- prefix, so this provider can never address a VM it did not name.
func ResolveID(instance string) string {
	if IsProviderID(instance) {
		return instance
	}
	return ProviderID(instance)
}

// ValidateImageName checks an srv image name.
func ValidateImageName(name string) error {
	if !srvNameRE.MatchString(name) {
		return fmt.Errorf("invalid srv image name %q", name)
	}
	return nil
}

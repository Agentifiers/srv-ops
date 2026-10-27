package provider

import "testing"

func TestProviderID(t *testing.T) {
	// printf %s garm-ny9HeeQYw2rl | sha256sum | cut -c1-16
	const want = "gha-4545a1e3d9f543fb"
	if got := ProviderID("garm-ny9HeeQYw2rl"); got != want {
		t.Fatalf("ProviderID = %q, want %q", got, want)
	}
	if ProviderID("garm-ny9HeeQYw2rl") == ProviderID("garm-ny9heeqyw2rl") {
		t.Fatal("names differing only in case must not collide")
	}
	for _, name := range []string{"garm-ny9HeeQYw2rl", "", "UPPER_case.name", "x"} {
		id := ProviderID(name)
		if !srvNameRE.MatchString(id) {
			t.Errorf("ProviderID(%q) = %q is not a valid srv name", name, id)
		}
		if !IsProviderID(id) {
			t.Errorf("IsProviderID(%q) = false", id)
		}
	}
}

func TestResolveID(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"gha-4545a1e3d9f543fb", "gha-4545a1e3d9f543fb"},
		{"garm-ny9HeeQYw2rl", "gha-4545a1e3d9f543fb"},
		// Not provider-ID shaped, so hashed rather than passed through.
		{"gha-4545A1E3D9F543FB", ProviderID("gha-4545A1E3D9F543FB")},
		{"orb-abc", ProviderID("orb-abc")},
	}
	for _, tt := range tests {
		if got := ResolveID(tt.in); got != tt.want {
			t.Errorf("ResolveID(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestValidateImageName(t *testing.T) {
	for _, ok := range []string{"gha-runner", "arch", "a", "a1-b2"} {
		if err := ValidateImageName(ok); err != nil {
			t.Errorf("ValidateImageName(%q) = %v", ok, err)
		}
	}
	for _, bad := range []string{"", "-x", "x-", "Gha", "a_b", "a/b", "--image"} {
		if err := ValidateImageName(bad); err == nil {
			t.Errorf("ValidateImageName(%q) accepted", bad)
		}
	}
}

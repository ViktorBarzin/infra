package main

import (
	"strings"
	"testing"
)

func TestUsageQuery(t *testing.T) {
	got := usageQuery("30d", "")
	want := `sum by (verb) (count_over_time({job="homelab-usage"}[30d]))`
	if got != want {
		t.Errorf("usageQuery(30d,\"\") = %q, want %q", got, want)
	}
	withUser := usageQuery("7d", "emo")
	if !strings.Contains(withUser, `user="emo"`) || !strings.Contains(withUser, "[7d]") {
		t.Errorf("usageQuery with user missing filter/range: %q", withUser)
	}
}

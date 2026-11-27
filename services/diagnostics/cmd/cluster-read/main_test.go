package main

import (
	"reflect"
	"testing"
	"time"
)

func TestParseFlags(t *testing.T) {
	f, err := parseFlags([]string{"-insecure-no-auth", "-log-namespaces", "a, b", "-status-namespaces", "c", "-deny-log-namespaces", "c,d", "-nodes=false", "-addr", ":9090", "-check-interval", "1m"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.cfg.LogNamespaces, []string{"a", "b"}) || !reflect.DeepEqual(f.cfg.StatusNamespaces, []string{"c"}) ||
		!reflect.DeepEqual(f.cfg.DenyLogNamespaces, []string{"c", "d"}) || f.cfg.Nodes || f.addr != ":9090" || f.checkEvery != time.Minute {
		t.Fatalf("%+v", f)
	}
}

func TestParseFlagsDefaultsAndRefusals(t *testing.T) {
	f, err := parseFlags([]string{"-bearer-file", "/var/run/secrets/openagentix/bearer/token"})
	if err != nil || f.bearerFile != "/var/run/secrets/openagentix/bearer/token" || f.insecure || !f.cfg.Nodes || f.addr != ":8080" || f.checkEvery != 5*time.Minute || len(f.cfg.LogNamespaces) != 0 {
		t.Fatalf("defaults: %+v %v", f, err)
	}
	for _, args := range [][]string{
		{}, // no bearer file and not insecure
		{"-bearer-file", "/x", "-insecure-no-auth"}, // both
		{"-bearer-file", "/x", "-log-namespaces", "*"},
		{"-bearer-file", "/x", "-log-namespaces", "kube-system"},
		{"-bearer-file", "/x", "-log-namespaces", "a", "-status-namespaces", "a"},
		{"-bearer-file", "/x", "-check-interval", "1s"},
		{"-unknown"},
	} {
		if _, err := parseFlags(args); err == nil {
			t.Errorf("%v accepted", args)
		}
	}
}

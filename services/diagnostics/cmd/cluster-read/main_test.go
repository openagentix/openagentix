package main

import (
	"reflect"
	"testing"
	"time"
)

func TestParseFlags(t *testing.T) {
	f, err := parseFlags([]string{"-log-namespaces", "a, b", "-status-namespaces", "c", "-deny-log-namespaces", "c,d", "-nodes=false", "-addr", ":9090", "-check-interval", "1m"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.cfg.LogNamespaces, []string{"a", "b"}) || !reflect.DeepEqual(f.cfg.StatusNamespaces, []string{"c"}) ||
		!reflect.DeepEqual(f.cfg.DenyLogNamespaces, []string{"c", "d"}) || f.cfg.Nodes || f.addr != ":9090" || f.checkEvery != time.Minute {
		t.Fatalf("%+v", f)
	}
}

func TestParseFlagsDefaultsAndRefusals(t *testing.T) {
	f, err := parseFlags(nil)
	if err != nil || !f.cfg.Nodes || f.addr != ":8080" || f.checkEvery != 5*time.Minute || len(f.cfg.LogNamespaces) != 0 {
		t.Fatalf("defaults: %+v %v", f, err)
	}
	for _, args := range [][]string{
		{"-log-namespaces", "*"},
		{"-log-namespaces", "kube-system"},
		{"-log-namespaces", "a", "-status-namespaces", "a"},
		{"-check-interval", "1s"},
		{"-unknown"},
	} {
		if _, err := parseFlags(args); err == nil {
			t.Errorf("%v accepted", args)
		}
	}
}

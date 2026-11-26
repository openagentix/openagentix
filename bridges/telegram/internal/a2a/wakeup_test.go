package a2a

import (
	"context"
	"strings"
	"testing"
)

func TestSend_InputNotAcceptedIsWaking(t *testing.T) {
	srv := fakeAgent(t, 200, `{"jsonrpc":"2.0","id":"1","error":{"code":-32004,"message":"input was not accepted; retry after the session becomes available"}}`, nil)
	defer srv.Close()
	_, _, err := NewClient(srv.URL, "", srv.Client()).Send(context.Background(), "", "hi")
	if !IsWaking(err) {
		t.Fatalf("IsWaking(%v) = false", err)
	}
	if !strings.Contains(err.Error(), "-32004") {
		t.Fatalf("message keeps the code: %v", err)
	}
}

func TestSend_OtherRPCErrorIsNotWaking(t *testing.T) {
	srv := fakeAgent(t, 200, `{"jsonrpc":"2.0","id":"1","error":{"code":-32001,"message":"Task not found"}}`, nil)
	defer srv.Close()
	_, _, err := NewClient(srv.URL, "", srv.Client()).Send(context.Background(), "", "hi")
	if err == nil || IsWaking(err) {
		t.Fatalf("err = %v", err)
	}
	if IsWaking(nil) {
		t.Fatal("nil is not waking")
	}
}

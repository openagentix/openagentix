package equipment

import (
	"context"
	"testing"
)

// The first measured real-model runs of the out of warranty case spent calls finding out that the machine has no telematics ("no telematics for this machine"),
// and one of them ended with the case sent to a person. get_machine says so up front.
func TestGetMachineSaysWhetherTheMachineHasTelematics(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	with, err := d.svc.GetMachine(ctx, "KH4120-00317")
	if err != nil {
		t.Fatal(err)
	}
	if !with.HasTelemetry {
		t.Error("KH4120-00317 reports telematics and get_machine must say so")
	}
	without, err := d.svc.GetMachine(ctx, "KH4120-00340")
	if err != nil {
		t.Fatal(err)
	}
	if without.HasTelemetry {
		t.Error("KH4120-00340 has no telematics and get_machine must say so")
	}
}

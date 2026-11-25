package container

import (
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

// A container agent's image is pulled again on every start unless the operator says otherwise: a digest on the node's disk is
// not proof that this namespace may run it. The quick start sets IfNotPresent because its image only exists on the node.
func TestImagePullPolicy(t *testing.T) {
	policy := func(c *catalog.Catalog) any {
		for _, m := range render(t, samplePlan(), c) {
			if m.Resource.Kind == "Deployment" {
				pod := m.Object["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
				return pod["containers"].([]any)[0].(map[string]any)["imagePullPolicy"]
			}
		}
		return nil
	}
	if got := policy(cat()); got != "Always" {
		t.Errorf("default imagePullPolicy = %v, want Always", got)
	}
	c := cat()
	c.Runtime.Container.ImagePullPolicy = "IfNotPresent"
	if got := policy(c); got != "IfNotPresent" {
		t.Errorf("configured imagePullPolicy = %v, want IfNotPresent", got)
	}
}

package realtime

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestLargeGroupNotifyKeepsEveryRecipientAndEvent(t *testing.T) {
	channels := make([]string, 5000)
	for i := range channels {
		channels[i] = fmt.Sprintf("visitor:00000000-0000-0000-0000-%012d", i)
	}
	event := json.RawMessage(`{"type":"group.updated","data":{"groupId":"福利群"}}`)
	batches := notifyEnvelopes("instance", channels, event)
	if len(batches) < 2 {
		t.Fatal("large group was not split")
	}
	index := 0
	for _, raw := range batches {
		if len(raw) >= 8000 {
			t.Fatalf("payload too large: %d", len(raw))
		}
		var env envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatal(err)
		}
		if string(env.Event) != string(event) {
			t.Fatal("group routing data lost")
		}
		for _, channel := range env.Channels {
			if index >= len(channels) || channel != channels[index] {
				t.Fatal("recipient lost or duplicated")
			}
			index++
		}
	}
	if index != len(channels) {
		t.Fatalf("only %d recipients", index)
	}
}

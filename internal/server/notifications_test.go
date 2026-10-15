package server

import "testing"

func TestPushEndpointRejectsInternalAndLookalikeHosts(t *testing.T) {
	for _, endpoint := range []string{"http://fcm.googleapis.com/send/x", "https://127.0.0.1/x", "https://localhost/x", "https://fcm.googleapis.com.attacker.example/x", "https://user@fcm.googleapis.com/x", "https://fcm.googleapis.com:8443/x", "https://fcm.googleapis.com/x#bad"} {
		if validPushEndpoint(endpoint) {
			t.Errorf("accepted unsafe endpoint %q", endpoint)
		}
	}
	for _, endpoint := range []string{"https://fcm.googleapis.com/fcm/send/x", "https://updates.push.services.mozilla.com/wpush/v2/x", "https://web.push.apple.com/x", "https://wns2.notify.windows.com/x"} {
		if !validPushEndpoint(endpoint) {
			t.Errorf("rejected supported endpoint %q", endpoint)
		}
	}
}

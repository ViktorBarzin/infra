package wire

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// goldenCase decodes a JSON body taken from docs/protocol.md into the type
// that owns it, then checks three things:
//
//  1. the decode rejects nothing, with DisallowUnknownFields on, so a field
//     the document defines and the type lacks is a failure rather than a
//     silent drop;
//  2. re-encoding and decoding again gives an identical value, so the tags
//     are not lossy;
//  3. every top-level key in the document survives the re-encode, which is
//     what stops an omitempty from swallowing a meaningful false or zero.
type goldenCase interface {
	caseName() string
	run(t *testing.T)
}

type golden[T any] struct {
	name string
	doc  string
}

func (g golden[T]) caseName() string { return g.name }

func (g golden[T]) run(t *testing.T) {
	t.Helper()

	// Fixtures are indented for reading. A json.RawMessage field keeps the
	// bytes it was given, so compare against the compact form or the
	// whitespace alone fails the round trip.
	doc := compact(t, g.doc)

	var first T
	if err := strictDecode(doc, &first); err != nil {
		t.Fatalf("decoding the documented body into %T failed: %v", first, err)
	}

	out, err := json.Marshal(first)
	if err != nil {
		t.Fatalf("re-encoding %T failed: %v", first, err)
	}

	var second T
	if err := strictDecode(string(out), &second); err != nil {
		t.Fatalf("decoding our own output back into %T failed: %v\noutput: %s", first, err, out)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("round trip changed the value\nfirst:  %#v\nsecond: %#v", first, second)
	}

	for _, key := range topLevelKeys(t, doc) {
		if _, ok := topLevelMap(t, string(out))[key]; !ok {
			t.Fatalf("key %q from the documented body is missing from our output\noutput: %s", key, out)
		}
	}
}

func compact(t *testing.T, doc string) string {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Compact(&buf, []byte(doc)); err != nil {
		t.Fatalf("fixture is not valid JSON: %v", err)
	}
	return buf.String()
}

func strictDecode[T any](doc string, into *T) error {
	dec := json.NewDecoder(strings.NewReader(doc))
	dec.DisallowUnknownFields()
	return dec.Decode(into)
}

func topLevelMap(t *testing.T, doc string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(doc), &m); err != nil {
		t.Fatalf("fixture is not a JSON object: %v", err)
	}
	return m
}

func topLevelKeys(t *testing.T, doc string) []string {
	t.Helper()
	keys := make([]string, 0, 8)
	for k := range topLevelMap(t, doc) {
		keys = append(keys, k)
	}
	return keys
}

func TestGoldenBodies(t *testing.T) {
	cases := []goldenCase{
		golden[CreateActionRequest]{"POST /v1/actions request", `{
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkL",
			"type": "input.click",
			"params": { "selector": "#submit" },
			"tab": "t_4k2p9xqa",
			"timeoutMs": 60000,
			"idempotencyKey": "optional-caller-supplied-string"
		}`},
		golden[CreateActionResponse]{"POST /v1/actions response", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi",
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "queueDepth": 2, "lane": "serial",
			"createdAt": 1758380000000, "expiresAt": 1758380060000
		}`},
		golden[ActionStatus]{"GET /v1/actions running", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "state": "running",
			"queuePosition": 0, "startedAt": 1758380000123
		}`},
		golden[ActionStatus]{"GET /v1/actions done", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg",
			"state": "done",
			"ok": true,
			"result": { "text": "Sign in" },
			"blob": { "blobId": "bl_MnBvCxZlKjHgFdSaPoIu", "bytes": 148213, "contentType": "image/png" },
			"tab": { "handle": "t_4k2p9xqa", "title": "Sign in", "origin": "https://example.com" },
			"startedAt": 1758380000123,
			"finishedAt": 1758380000456
		}`},
		golden[ActionStatus]{"GET /v1/actions failed", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "state": "done", "ok": false,
			"error": { "code": "tab_closed", "message": "the tab was closed while the action was running",
			           "hint": "run tabs to list them", "retryable": false }
		}`},
		golden[CancelActionResponse]{"DELETE /v1/actions", `{"state": "cancelled"}`},
		golden[StopResponse]{"POST /v1/control/stop", `{
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "stopEpoch": 7, "cancelled": 3, "browserLive": true
		}`},
		golden[BrowsersResponse]{"GET /v1/browsers", `{ "browsers": [
			{ "browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "label": "wizard-mbp Chrome", "default": true, "live": true,
			  "lastSeenAt": 1758380000000, "enrolledAt": 1755780000000, "expiresAt": 1760972000000,
			  "extensionVersion": "0.1.0", "queueDepth": 0, "stopEpoch": 7, "stopped": false }
		] }`},
		golden[StatusResponse]{"GET /v1/status", `{
			"server": { "version": "0.1.0", "protocol": 1, "storeOk": true },
			"user": "wizard",
			"browser": { "browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "label": "wizard-mbp Chrome", "live": true,
			             "stopped": false, "queueDepth": 0, "currentAction": null, "extensionVersion": "0.1.0" },
			"session": { "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi", "expiresAt": 1758466400000, "currentTab": "t_4k2p9xqa" }
		}`},
		golden[ActivityResponse]{"GET /v1/activity", `{ "entries": [
			{ "seq": 412, "at": 1758380000456, "kind": "action", "type": "input.click",
			  "tab": "t_4k2p9xqa", "title": "Sign in to Example", "origin": "https://example.com",
			  "path": "/login", "owner": "user", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi", "outcome": "ok" }
		] }`},
		golden[ActivityEntry]{"activity entry, full", `{
			"seq": 412, "at": 1758380000456, "kind": "action", "type": "input.click",
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi",
			"agentLabel": "wizard@devvm", "tab": "t_4k2p9xqa", "title": "Sign in to Example",
			"origin": "https://example.com", "path": "/login", "owner": "user",
			"outcome": "ok", "durationMs": 312
		}`},
		golden[ActivityPushRequest]{"POST /v1/activity", `{ "entries": [
			{ "seq": 412, "at": 1758380000456, "kind": "action", "type": "input.click",
			  "tab": "t_4k2p9xqa", "title": "Sign in to Example", "origin": "https://example.com",
			  "path": "/login", "owner": "user", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi", "outcome": "ok" }
		] }`},
		golden[ActivityPushResponse]{"POST /v1/activity response", `{"accepted": 12}`},
		golden[ResultRequest]{"POST /v1/results ok", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "ok": true, "result": { "text": "Sign in" },
			"blobId": "bl_MnBvCxZlKjHgFdSaPoIu",
			"tab": { "handle": "t_4k2p9xqa", "title": "Sign in", "origin": "https://example.com" },
			"startedAt": 1758380000123, "finishedAt": 1758380000456
		}`},
		golden[ResultRequest]{"POST /v1/results failed", `{
			"actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "ok": false,
			"error": { "code": "tab_closed", "message": "the tab was closed", "hint": "run tabs", "retryable": false },
			"finishedAt": 1758380000456
		}`},
		golden[ResultResponse]{"POST /v1/results response", `{"ok": true, "duplicate": true}`},
		golden[QueueStateRequest]{"POST /v1/queue-state", `{
			"queueDepth": 2, "offQueueCount": 1, "currentAction": "a_ZxCvBnMqWeRtYuIoPaSdFg", "attachedTabs": 3
		}`},
		golden[BlobUploadResponse]{"POST /v1/blobs", `{
			"blobId": "bl_MnBvCxZlKjHgFdSaPoIu", "bytes": 148213, "expiresAt": 1758380600000
		}`},
		golden[PairRequest]{"POST /v1/pair request", `{"label": "work laptop"}`},
		golden[PairResponse]{"POST /v1/pair response", `{
			"code": "K7M2QX", "expiresAt": 1758380600000, "attemptsLeft": 5
		}`},
		golden[PairRedeemRequest]{"POST /v1/pair/redeem request", `{
			"code": "K7M2QX", "extensionId": "abcdefghijklmnopabcdefghijklmnop", "label": "work laptop"
		}`},
		golden[PairRedeemResponse]{"POST /v1/pair/redeem response", `{
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "browserKey": "0123456789012345678901234567890123456789012",
			"owner": "wizard", "expiresAt": 1760972000000
		}`},
		golden[EnrolRequest]{"POST /v1/enrol request", `{
			"extensionId": "abcdefghijklmnopabcdefghijklmnop", "nonce": "3f2a", "label": "wizard-mbp Chrome"
		}`},
		golden[EnrolResponse]{"POST /v1/enrol response", `{
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "browserKey": "0123456789012345678901234567890123456789012",
			"expiresAt": 1760972000000, "default": true
		}`},
		golden[PatchBrowserRequest]{"PATCH /v1/browsers", `{
			"label": "wizard-mbp Chrome",
			"settings": { "cursorOverlay": true, "groupAgentTabs": true, "groupColor": "cyan", "idleDetachMs": 600000 }
		}`},
		golden[AdminTokenRequest]{"POST /v1/admin/tokens request", `{"osUser": "emo", "authentikUser": "emo"}`},
		golden[AdminTokenResponse]{"POST /v1/admin/tokens response", `{"token": "0123456789", "osUser": "emo"}`},

		// SSE frames, section 6.
		golden[ReadyFrame]{"event: ready", `{
			"v": 1, "seq": 1, "browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm", "serverTime": 1758380000000,
			"serverVersion": "0.1.0", "heartbeatMs": 15000, "stopEpoch": 7,
			"replayCount": 2, "enrolmentExpiresAt": 1760972000000
		}`},
		golden[HeartbeatFrame]{"event: heartbeat", `{
			"v": 1, "seq": 42, "serverTime": 1758380015000, "queueDepth": 0
		}`},
		golden[ActionFrame]{"event: action", `{
			"v": 1, "seq": 43, "actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi",
			"type": "input.click", "params": { "selector": "#submit" }, "tab": "t_4k2p9xqa",
			"createdAt": 1758380000000, "timeoutMs": 60000, "expiresAt": 1758380090000,
			"lane": "serial", "replay": false, "agentLabel": "wizard@devvm"
		}`},
		golden[CancelFrame]{"event: cancel", `{
			"v": 1, "seq": 44, "actionId": "a_ZxCvBnMqWeRtYuIoPaSdFg", "reason": "expired"
		}`},
		golden[ControlFrame]{"event: control", `{"v": 1, "seq": 45, "op": "stop", "stopEpoch": 8}`},
		golden[SettingsFrame]{"event: settings", `{
			"v": 1, "seq": 2,
			"settings": { "cursorOverlay": true, "groupAgentTabs": true, "groupColor": "cyan",
			              "idleDetachMs": 600000, "activityMirror": true },
			"label": "wizard-mbp Chrome", "version": 12
		}`},
		golden[ErrorFrame]{"event: error", `{
			"v": 1, "seq": 46, "code": "store_unavailable", "message": "redis is unreachable"
		}`},

		// Action results, sections 11 and 14.
		golden[TabListResult]{"tab.list result", `{
			"browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm",
			"at": 1758380000000,
			"windows": [ { "windowId": 12, "focused": true, "tabCount": 9, "state": "normal" } ],
			"tabs": [
				{ "tab": "t_4k2p9xqa", "chromeTabId": 4471, "title": "Sign in to Example",
				  "url": "https://example.com/login", "origin": "https://example.com",
				  "windowId": 12, "index": 3, "active": false, "audible": false, "discarded": false,
				  "group": { "groupId": 88, "title": "agent wizard@devvm", "color": "cyan" },
				  "owner": "agent", "sessionId": "s_QaZwSxEdCrFvTgByHnUjMi", "attached": true,
				  "attachedBy": "s_QaZwSxEdCrFvTgByHnUjMi", "attachedAt": 1758379000000,
				  "rebound": false, "state": "open" }
			],
			"truncated": false
		}`},
		golden[AttachResult]{"tab.attach result", `{
			"tab": "t_4k2p9xqa", "title": "Sign in to Example", "origin": "https://example.com",
			"owner": "user", "bannerShown": true
		}`},
		golden[DetachResult]{"tab.detach result", `{
			"tab": "t_4k2p9xqa", "wasAttached": true, "clearedOverrides": ["emulation", "network"]
		}`},
		golden[ActivateResult]{"tab.activate result", `{"tab": "t_4k2p9xqa", "windowId": 12, "focused": true}`},
		golden[CloseTabResult]{"tab.close result", `{"tab": "t_4k2p9xqa", "closed": true, "owner": "user"}`},
		golden[PingResult]{"ctl.ping result", `{
			"roundTripMs": 41, "extensionVersion": "0.1.0", "queueDepth": 0, "attachedTabs": 2
		}`},
		golden[OpenResult]{"nav.open result", `{
			"tab": "t_4k2p9xqa", "url": "https://example.com/login", "title": "Sign in",
			"statusCode": 200, "loadMs": 812
		}`},
		golden[URLResult]{"nav.url result", `{
			"url": "https://example.com/login", "title": "Sign in",
			"origin": "https://example.com", "readyState": "complete"
		}`},
		golden[QueryResult]{"read.query result", `{
			"count": 1,
			"matches": [ { "index": 0, "tag": "button", "text": "Sign in",
			               "attrs": { "type": "submit" }, "visible": true,
			               "box": { "x": 12.5, "y": 480, "width": 96, "height": 32 } } ]
		}`},
		golden[ScreenshotResult]{"read.screenshot result", `{
			"blobId": "bl_MnBvCxZlKjHgFdSaPoIu", "width": 1512, "height": 982, "bytes": 148213
		}`},
		golden[ConsoleResult]{"diag.console result", `{
			"count": 1,
			"entries": [ { "at": 1758380000456, "level": "error", "text": "Uncaught TypeError",
			               "source": "https://example.com/app.js", "line": 42 } ]
		}`},
		golden[NetworkResult]{"diag.network list result", `{
			"count": 1,
			"requests": [ { "id": 7, "method": "POST", "url": "https://example.com/login",
			                "status": 302, "type": "document", "bytes": 1841, "ms": 219 } ]
		}`},
		golden[EmulateResult]{"diag.emulate result", `{
			"applied": ["viewport", "colorScheme"], "cleared": ["network"]
		}`},
		golden[WaitForResult]{"wait.for result", `{"matched": true, "what": "selector", "waitedMs": 1840}`},
		golden[FillResult]{"input.fill result", `{"filled": 3, "failed": []}`},
	}

	seen := map[string]bool{}
	for _, c := range cases {
		if seen[c.caseName()] {
			t.Fatalf("duplicate fixture name %q", c.caseName())
		}
		seen[c.caseName()] = true
		t.Run(c.caseName(), c.run)
	}
}

func TestActionFrameCarriesRawParams(t *testing.T) {
	const doc = `{"v":1,"seq":43,"actionId":"a_ZxCvBnMqWeRtYuIoPaSdFg","sessionId":"s_QaZwSxEdCrFvTgByHnUjMi","type":"input.click","params":{"selector":"#submit"},"tab":"t_4k2p9xqa","createdAt":1758380000000,"timeoutMs":60000,"expiresAt":1758380090000,"lane":"serial","replay":false,"agentLabel":"wizard@devvm"}`
	var f ActionFrame
	if err := json.Unmarshal([]byte(doc), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	var p ClickParams
	if err := json.Unmarshal(f.Params, &p); err != nil {
		t.Fatalf("params did not decode into ClickParams: %v", err)
	}
	if p.Selector != "#submit" {
		t.Fatalf("selector = %q", p.Selector)
	}
	out, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.Contains(out, []byte(`"params":{"selector":"#submit"}`)) {
		t.Fatalf("params were re-encoded, not passed through: %s", out)
	}
}

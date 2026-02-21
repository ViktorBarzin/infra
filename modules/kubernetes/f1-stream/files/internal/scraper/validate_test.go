package scraper

import "testing"

func TestContainsVideoMarkers(t *testing.T) {
	tests := []struct {
		name string
		body string
		want bool
	}{
		// Positive cases
		{
			name: "video tag",
			body: `<div><video src="stream.mp4"></video></div>`,
			want: true,
		},
		{
			name: "HLS manifest reference",
			body: `var url = "https://cdn.example.com/live.m3u8";`,
			want: true,
		},
		{
			name: "DASH manifest reference",
			body: `<source src="stream.mpd" type="application/dash+xml">`,
			want: true,
		},
		{
			name: "HLS.js library",
			body: `<script src="/js/hls.min.js"></script>`,
			want: true,
		},
		{
			name: "Video.js library",
			body: `<script src="https://cdn.example.com/video.js"></script>`,
			want: true,
		},
		{
			name: "JW Player",
			body: `<div id="jwplayer-container"></div><script>jwplayer("jwplayer-container")</script>`,
			want: true,
		},
		{
			name: "Clappr player",
			body: `<script src="clappr.min.js"></script>`,
			want: true,
		},
		{
			name: "Flowplayer",
			body: `<script>flowplayer("#player")</script>`,
			want: true,
		},
		{
			name: "Plyr player",
			body: `<link rel="stylesheet" href="plyr.css"><script src="plyr.js"></script>`,
			want: true,
		},
		{
			name: "Shaka Player",
			body: `<script src="shaka-player.compiled.js"></script>`,
			want: true,
		},
		// Negative cases
		{
			name: "plain HTML",
			body: `<html><body><p>Hello world</p></body></html>`,
			want: false,
		},
		{
			name: "reddit link page",
			body: `<html><body><a href="https://example.com">Click here</a></body></html>`,
			want: false,
		},
		{
			name: "blog post",
			body: `<html><body><article>F1 race results and analysis...</article></body></html>`,
			want: false,
		},
		{
			name: "empty string",
			body: "",
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := containsVideoMarkers(tt.body)
			if got != tt.want {
				t.Errorf("containsVideoMarkers(%q) = %v, want %v", truncate(tt.body, 60), got, tt.want)
			}
		})
	}
}

func TestIsDirectVideoContentType(t *testing.T) {
	tests := []struct {
		name string
		ct   string
		want bool
	}{
		// Positive cases
		{name: "video/mp4", ct: "video/mp4", want: true},
		{name: "video/webm", ct: "video/webm", want: true},
		{name: "HLS content type", ct: "application/x-mpegurl", want: true},
		{name: "Apple HLS content type", ct: "application/vnd.apple.mpegurl", want: true},
		{name: "DASH content type", ct: "application/dash+xml", want: true},
		{name: "video with params", ct: "video/mp4; charset=utf-8", want: true},
		// Negative cases
		{name: "text/html", ct: "text/html", want: false},
		{name: "application/json", ct: "application/json", want: false},
		{name: "image/png", ct: "image/png", want: false},
		{name: "text/plain", ct: "text/plain", want: false},
		{name: "empty string", ct: "", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isDirectVideoContentType(tt.ct)
			if got != tt.want {
				t.Errorf("isDirectVideoContentType(%q) = %v, want %v", tt.ct, got, tt.want)
			}
		})
	}
}

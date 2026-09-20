package wire

// Blobs carry the payloads too big for a frame: screenshots, a truncated
// read, a captured response body. The extension uploads them out of band and
// the CLI fetches them out of band. Bytes never travel through SSE and never
// go into Redis.

// BlobRef points at a large result payload held by the server. A blob is
// dropped 60 seconds after its first successful fetch, or at its 10 minute
// TTL, whichever comes first.
type BlobRef struct {
	BlobID      string `json:"blobId"`
	Bytes       int64  `json:"bytes"`
	ContentType string `json:"contentType,omitempty"`
}

// BlobUploadResponse is the 201 from POST /v1/blobs.
type BlobUploadResponse struct {
	BlobID    string `json:"blobId"`
	Bytes     int64  `json:"bytes"`
	ExpiresAt int64  `json:"expiresAt"`
}

package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

// Large results never travel as base64 inside a struct. The extension
// uploads them to the server and the client streams them back from here.

// blobBody ties the response body to the context that governs it, so closing
// the reader releases the request.
type blobBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *blobBody) Close() error {
	err := b.ReadCloser.Close()
	b.cancel()
	return err
}

// FetchBlob streams one blob. The caller closes the reader. A blob is dropped
// 60 seconds after its first successful fetch, so this works once.
func (c *Client) FetchBlob(ctx context.Context, blobID string) (io.ReadCloser, *wire.BlobRef, error) {
	if blobID == "" {
		return nil, nil, &UsageError{Message: "no blob id"}
	}
	path := wire.RoutePrefix + "/blobs/" + blobID

	ctx, cancel := c.withTimeout(ctx, c.blobTimeout)
	resp, err := c.request(ctx, http.MethodGet, path, nil, nil, c.session)
	if err != nil {
		cancel()
		return nil, nil, err
	}
	if resp.StatusCode >= 300 {
		out, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		cancel()
		return nil, nil, classifyHTTP(http.MethodGet, path, resp.StatusCode, out, c.user, c.baseURL)
	}

	info := &wire.BlobRef{BlobID: blobID, ContentType: resp.Header.Get("Content-Type")}
	if n, err := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64); err == nil {
		info.Bytes = n
	}
	return &blobBody{ReadCloser: resp.Body, cancel: cancel}, info, nil
}

// BlobBytes reads a whole blob into memory. Screenshots run to a few
// megabytes, so a caller writing to a file should prefer FetchBlob.
func (c *Client) BlobBytes(ctx context.Context, blobID string) ([]byte, *wire.BlobRef, error) {
	body, info, err := c.FetchBlob(ctx, blobID)
	if err != nil {
		return nil, nil, err
	}
	defer body.Close()

	out, err := io.ReadAll(io.LimitReader(body, wire.MaxBlobBytes+1))
	if err != nil {
		return nil, info, &TransportError{
			Op:  "GET " + wire.RoutePrefix + "/blobs/" + blobID,
			Err: fmt.Errorf("reading the blob, %w", err),
		}
	}
	if len(out) > wire.MaxBlobBytes {
		return nil, info, &TransportError{
			Op:  "GET " + wire.RoutePrefix + "/blobs/" + blobID,
			Err: fmt.Errorf("the blob is over the %d byte cap", wire.MaxBlobBytes),
		}
	}
	return out, info, nil
}

// ScreenshotTo captures the tab and writes the image to w, which is the whole
// of the `screenshot --output` command.
func (c *Client) ScreenshotTo(ctx context.Context, t Target, p wire.ScreenshotParams, w io.Writer) (*wire.ScreenshotResult, error) {
	shot, err := c.Screenshot(ctx, t, p)
	if err != nil {
		return nil, err
	}
	if shot.BlobID == "" {
		return shot, &TransportError{
			Op:  "POST " + wire.RoutePrefix + "/actions",
			Err: fmt.Errorf("the screenshot result carries no blob id"),
		}
	}
	body, _, err := c.FetchBlob(ctx, shot.BlobID)
	if err != nil {
		return shot, err
	}
	defer body.Close()

	if _, err := io.Copy(w, io.LimitReader(body, wire.MaxBlobBytes)); err != nil {
		return shot, &TransportError{
			Op:  "GET " + wire.RoutePrefix + "/blobs/" + shot.BlobID,
			Err: fmt.Errorf("writing the screenshot, %w", err),
		}
	}
	return shot, nil
}

// marshal encodes a request body, turning the impossible failure into a
// usage error rather than a panic.
func marshal[T any](v T) ([]byte, error) {
	out, err := json.Marshal(v)
	if err != nil {
		return nil, &UsageError{Message: fmt.Sprintf("cannot encode the request body, %v", err)}
	}
	return out, nil
}

// player.js — Native HLS player management using HLS.js directly

var _hlsInstance = null;
var _videoElement = null;

/**
 * Fetch player config for a stream from the backend.
 * Returns {type: "hls"|"daddylive"|"proxy", hls_url, auth_token, ...}
 */
async function getPlayerConfig(streamId) {
  try {
    const resp = await fetch('/api/streams/' + streamId + '/player-config');
    if (!resp.ok) return { type: 'proxy' };
    return await resp.json();
  } catch (e) {
    console.error('Failed to fetch player config:', e);
    return { type: 'proxy' };
  }
}

/**
 * Decode a /hls/{b64} URL back to the original upstream URL.
 */
function decodeHLSURL(proxyURL) {
  if (!proxyURL || typeof proxyURL !== 'string') return proxyURL;
  var m = proxyURL.match(/\/hls\/([A-Za-z0-9_-]+)/);
  if (!m) return proxyURL;
  try {
    // base64url decode
    var b64 = m[1].replace(/-/g, '+').replace(/_/g, '/');
    // pad
    while (b64.length % 4 !== 0) b64 += '=';
    return atob(b64);
  } catch (e) {
    return proxyURL;
  }
}

/**
 * Create an HLS.js player for a plain HLS stream.
 */
function createHLSPlayer(containerSelector, hlsURL) {
  destroyNativePlayer();
  _buildPlayer(containerSelector, hlsURL, {});
}

/**
 * Create an HLS.js player for DaddyLive streams with auth module integration.
 */
function createDaddyLivePlayer(containerSelector, config) {
  destroyNativePlayer();

  if (config.auth_mod_url) {
    _loadAuthModAndPlay(containerSelector, config);
  } else {
    _buildPlayer(containerSelector, config.hls_url, {});
  }
}

function _loadAuthModAndPlay(containerSelector, config) {
  var script = document.createElement('script');
  script.src = config.auth_mod_url;
  script.onload = function () {
    _createDaddyLivePlayerWithAuth(containerSelector, config);
  };
  script.onerror = function () {
    console.warn('Failed to load auth module, falling back to direct HLS');
    _buildPlayer(containerSelector, config.hls_url, {});
  };
  document.head.appendChild(script);
}

function _createDaddyLivePlayerWithAuth(containerSelector, config) {
  var hlsConfig = {};

  // If EPlayerAuth is available, set up xhr wrapping
  if (typeof EPlayerAuth !== 'undefined' && typeof EPlayerAuth.init === 'function') {
    try {
      EPlayerAuth.init({
        authToken: config.auth_token,
        channelKey: config.channel_key,
        channelSalt: config.channel_salt,
        timestamp: config.timestamp,
        serverKey: config.server_key
      });

      if (typeof EPlayerAuth.getXhrSetup === 'function') {
        var origSetup = EPlayerAuth.getXhrSetup();
        hlsConfig.xhrSetup = function (xhr, url) {
          // Decode the real upstream URL from our /hls/{b64} proxy path
          var realURL = decodeHLSURL(url);

          // Create interceptor to capture headers the auth module sets
          var captured = {};
          var fakeXHR = {
            setRequestHeader: function (k, v) { captured[k] = v; }
          };

          try {
            origSetup(fakeXHR, realURL);
          } catch (e) {
            console.warn('Auth xhrSetup error:', e);
          }

          // Re-set captured headers with forwarding prefix
          for (var k in captured) {
            if (captured.hasOwnProperty(k)) {
              xhr.setRequestHeader('X-Hls-Forward-' + k, captured[k]);
            }
          }
        };
      }
    } catch (e) {
      console.warn('EPlayerAuth init failed:', e);
    }
  }

  _buildPlayer(containerSelector, config.hls_url, hlsConfig);
}

/**
 * Build an HLS.js player with a <video> element.
 */
function _buildPlayer(containerSelector, hlsURL, extraConfig) {
  var container = document.querySelector(containerSelector);
  if (!container) return;

  // Create video element
  var video = document.createElement('video');
  video.controls = true;
  video.autoplay = true;
  video.style.width = '100%';
  video.style.height = '100%';
  video.style.backgroundColor = '#000';
  container.appendChild(video);
  _videoElement = video;

  if (Hls.isSupported()) {
    var config = {
      enableWorker: true,
      lowLatencyMode: false,
      maxBufferLength: 30,
      maxMaxBufferLength: 60
    };
    // Merge extra config (e.g. xhrSetup for auth)
    for (var k in extraConfig) {
      if (extraConfig.hasOwnProperty(k)) {
        config[k] = extraConfig[k];
      }
    }

    var hls = new Hls(config);
    hls.loadSource(hlsURL);
    hls.attachMedia(video);
    hls.on(Hls.Events.MANIFEST_PARSED, function () {
      video.play().catch(function(e) {
        console.warn('Autoplay blocked:', e);
      });
    });
    hls.on(Hls.Events.ERROR, function (event, data) {
      console.error('HLS.js error:', data.type, data.details, data);
      if (data.fatal) {
        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            console.warn('HLS network error, attempting recovery...');
            hls.startLoad();
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            console.warn('HLS media error, attempting recovery...');
            hls.recoverMediaError();
            break;
          default:
            console.error('HLS fatal error, cannot recover');
            hls.destroy();
            break;
        }
      }
    });
    _hlsInstance = hls;
  } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
    // Safari native HLS
    video.src = hlsURL;
    video.addEventListener('loadedmetadata', function () {
      video.play().catch(function(e) {
        console.warn('Autoplay blocked:', e);
      });
    });
  } else {
    container.textContent = 'HLS playback is not supported in this browser.';
  }
}

/**
 * Destroy the current native player instance.
 */
function destroyNativePlayer() {
  if (_hlsInstance) {
    try {
      _hlsInstance.destroy();
    } catch (e) {
      console.warn('Error destroying HLS instance:', e);
    }
    _hlsInstance = null;
  }
  if (_videoElement) {
    try {
      _videoElement.pause();
      _videoElement.removeAttribute('src');
      _videoElement.load();
      _videoElement.remove();
    } catch (e) {
      console.warn('Error removing video element:', e);
    }
    _videoElement = null;
  }
}

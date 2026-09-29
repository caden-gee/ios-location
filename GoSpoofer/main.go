package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"math"
	"math/big"
	"net"
	"net/http"
	"runtime/cgo"
	"strings"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
	pb "golocationspoofer/pb"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

//#cgo CFLAGS: -DGOOS_ios -DNDEBUG
//#include <stdint.h>
//#include <stdlib.h>
import "C"

var globalCACert *tls.Certificate

// spoofLat/spoofLon/spoofingEnabled are written from the tunnel thread via
// startproxy and read from the proxy's request goroutines, so guard them.
var (
	spoofMu         sync.RWMutex
	spoofLat        float64
	spoofLon        float64
	spoofingEnabled bool
)

func setSpoofConfig(lat, lon float64, enabled bool) {
	spoofMu.Lock()
	spoofLat, spoofLon, spoofingEnabled = lat, lon, enabled
	spoofMu.Unlock()
}

func spoofConfig() (lat, lon float64, enabled bool) {
	spoofMu.RLock()
	defer spoofMu.RUnlock()
	return spoofLat, spoofLon, spoofingEnabled
}

// wlocResponseHeader is the fixed prefix Apple's /clls/wloc responses start with,
// followed by a big-endian u16 payload length and the protobuf payload.
var wlocResponseHeader = []byte{0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00}

// 诊断日志环形缓冲:最近 maxLogEntries 条 logEvent 调用,带时间戳。
// drainlogs 导出函数返回缓冲内容(C 串)给 Tunnel→App 诊断面板,clear 缓冲。
const maxLogEntries = 200

var logBuffer = make([]string, 0, maxLogEntries)
var logBufferMu sync.Mutex

func logEvent(msg string) {
	stamp := time.Now().Format("15:04:05.000")
	line := stamp + "  " + msg
	logBufferMu.Lock()
	logBuffer = append(logBuffer, line)
	if len(logBuffer) > maxLogEntries {
		logBuffer = logBuffer[len(logBuffer)-maxLogEntries:]
	}
	logBufferMu.Unlock()
	// 同步写一份到 stderr(开发环境 Mac+Console.app 可见),保留原日志通路
	log.Printf("%s", msg)
}

//export golocationspoofer_drainlogs
func golocationspoofer_drainlogs() *C.char {
	logBufferMu.Lock()
	combined := strings.Join(logBuffer, "\n")
	logBuffer = logBuffer[:0]
	logBufferMu.Unlock()
	return C.CString(combined)
}

//export golocationspoofer_version
func golocationspoofer_version() *C.char {
	return C.CString("1.0.0")
}

//export golocationspoofer_generateca
func golocationspoofer_generateca() (r0, r1 *C.char) {
	certPEM, keyPEM, err := generateCA()
	if err != nil {
		return nil, nil
	}
	return C.CString(string(certPEM)), C.CString(string(keyPEM))
}

//export golocationspoofer_startproxy
func golocationspoofer_startproxy(certData *C.char, keyData *C.char, lat C.double, lon C.double, enabled C.int) C.uintptr_t {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in startproxy: %v", r)
		}
	}()

	setSpoofConfig(float64(lat), float64(lon), enabled != 0)

	if certData != nil && keyData != nil {
		certPEM := C.GoString(certData)
		keyPEM := C.GoString(keyData)

		parsedCert, err := parseCA([]byte(certPEM), []byte(keyPEM))
		if err != nil {
			log.Printf("Failed to parse CA cert: %v", err)
			return 0
		}
		globalCACert = parsedCert
		log.Printf("Location spoofer: MITM enabled, coordinates: %.6f, %.6f", float64(lat), float64(lon))
	}

	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	if globalCACert != nil {
		setupMITM(proxy, globalCACert)
		setupCertServing(proxy, globalCACert)
	}

	if enabled != 0 {
		setupLocationSpoofing(proxy)
	}

	// Bind synchronously so a failure (e.g. port still held by a previous
	// tunnel instance) is reported to Swift instead of a handle to a dead server.
	ln, err := net.Listen("tcp", "127.0.0.1:8888")
	if err != nil {
		log.Printf("Failed to listen on 127.0.0.1:8888: %v", err)
		return 0
	}

	srv := &http.Server{Handler: proxy}

	h := cgo.NewHandle(srv)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in HTTP server: %v", r)
			}
		}()
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	log.Printf("Proxy server started on 127.0.0.1:8888")
	return C.uintptr_t(h)
}

//export golocationspoofer_stopproxy
func golocationspoofer_stopproxy(h C.uintptr_t) C.int {
	handle := cgo.Handle(h)
	srv, ok := handle.Value().(*http.Server)
	if !ok {
		handle.Delete()
		return 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err := srv.Shutdown(ctx)
	handle.Delete()
	if err != nil {
		return 2
	}
	return 0
}

//export golocationspoofer_getcoords
func golocationspoofer_getcoords() (lat, lon C.double, enabled C.int) {
	curLat, curLon, curEnabled := spoofConfig()
	var e C.int = 0
	if curEnabled {
		e = 1
	}
	return C.double(curLat), C.double(curLon), e
}

func setupMITM(proxy *goproxy.ProxyHttpServer, cert *tls.Certificate) {
	customCaMitm := &goproxy.ConnectAction{
		Action:    goproxy.ConnectMitm,
		TLSConfig: goproxy.TLSConfigFromCA(cert),
	}

	var customMitmHandler goproxy.FuncHttpsHandler = func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		hostname := strings.Split(host, ":")[0]
		if hostname == "gs-loc.apple.com" || hostname == "gs-loc-cn.apple.com" {
			log.Printf("Intercepting location request: %s", host)
			return customCaMitm, host
		}
		return goproxy.OkConnect, host
	}

	proxy.OnRequest().HandleConnect(customMitmHandler)
}

func setupCertServing(proxy *goproxy.ProxyHttpServer, cert *tls.Certificate) {
	certDER := cert.Certificate[0]
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})

	// rendoor.cert/ 收到的请求先返回这个等待页,2 秒后 meta refresh 跳 /cert 真证书。
	// 给用户视觉反馈"事情在动",避免 Safari 空白几百毫秒后突然弹下载框的突兀感。
	const waitPageHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta http-equiv="refresh" content="2;url=/cert">
<title>Preparing configuration profile</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,system-ui;background:#fff;color:#222;display:flex;flex-direction:column;justify-content:center;align-items:center;min-height:100vh;margin:0;padding:20px;text-align:center}
.title{font-size:24px;font-weight:600;margin-bottom:16px}
.subtitle{font-size:14px;color:#666;line-height:1.6;max-width:320px}
.fallback{margin-top:32px;font-size:13px}
a{color:#007AFF;text-decoration:none}
</style>
</head>
<body>
<div class="title">Preparing configuration profile…</div>
<div class="subtitle">Please wait, the system will show an install prompt shortly.<br>Do not close this page.</div>
<div class="fallback">If the prompt does not appear, <a href="/cert">tap here to download manually</a></div>
</body>
</html>`

	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		// 兼容:mitm.it 旧路径无视 path,直接返回证书。
		if req.Host == "mitm.it" || req.Host == "www.mitm.it" {
			resp := goproxy.NewResponse(req, "application/x-x509-ca-cert", http.StatusOK, string(certPEM))
			resp.Header.Set("Content-Disposition", "attachment; filename=mitm-ca.crt")
			return req, resp
		}
		// rendoor.cert:按 path 分流。/cert 真下载,其他(含 /)是 HTML 等待页。
		if req.Host == "rendoor.cert" || req.Host == "www.rendoor.cert" {
			if req.URL.Path == "/cert" {
				resp := goproxy.NewResponse(req, "application/x-x509-ca-cert", http.StatusOK, string(certPEM))
				resp.Header.Set("Content-Disposition", "attachment; filename=mitm-ca.crt")
				return req, resp
			}
			return req, goproxy.NewResponse(req, "text/html; charset=utf-8", http.StatusOK, waitPageHTML)
		}
		return req, nil
	})
}

func setupLocationSpoofing(proxy *goproxy.ProxyHttpServer) {
	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		if req.Host == "gs-loc.apple.com" || req.Host == "gs-loc-cn.apple.com" {
			if req.URL.Path == "/clls/wloc" && req.Method == "POST" {
				return handleLocationRequest(req)
			}
		}
		return req, nil
	})
}

// handleLocationRequest rewrites a /clls/wloc request into a response that
// places every queried access point at the spoof coordinates. On any parse
// failure it returns the request untouched (with its body restored) so it is
// forwarded to Apple and location keeps working unspoofed.
func handleLocationRequest(req *http.Request) (outReq *http.Request, outResp *http.Response) {
	outReq = req
	defer func() {
		if r := recover(); r != nil {
			logEvent(fmt.Sprintf("PANIC in handleLocationRequest: %v, passing through", r))
			outReq, outResp = req, nil
		}
	}()

	logEvent(fmt.Sprintf("Location request received Host=%s Path=%s Method=%s", req.Host, req.URL.Path, req.Method))

	body, err := io.ReadAll(req.Body)
	req.Body.Close()
	// Put the body back so every pass-through path forwards the original bytes.
	req.Body = io.NopCloser(bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	if err != nil {
		logEvent(fmt.Sprintf("Failed to read request body: %v, passing through", err))
		return req, nil
	}
	logEvent(fmt.Sprintf("Request body read length=%d bytes", len(body)))

	arpc, err := ArpcDeserialize(body)
	if err != nil {
		logEvent(fmt.Sprintf("ARPC parse failed: %v, passing through", err))
		return req, nil
	}
	logEvent(fmt.Sprintf("ARPC parsed OK version=%s payloadLen=%d", arpc.Version, len(arpc.Payload)))

	// Only used to validate the payload and count devices; the rewrite below
	// works on raw wire bytes so unknown fields survive.
	wloc := &pb.AppleWLoc{}
	if err := proto.Unmarshal(arpc.Payload, wloc); err != nil {
		logEvent(fmt.Sprintf("protobuf Unmarshal failed: %v, passing through", err))
		return req, nil
	}
	wifiCount := len(wloc.WifiDevices)
	logEvent(fmt.Sprintf("AppleWLoc parsed wifiCount=%d", wifiCount))

	curLat, curLon, _ := spoofConfig()
	newPayload, modifiedFields := rewriteAppleWLocCoords(arpc.Payload, IntFromCoord(curLat), IntFromCoord(curLon))
	logEvent(fmt.Sprintf("raw wire rewrite done in=%d B out=%d B modified %d lat/lon fields (spoof=(%.6f, %.6f))", len(arpc.Payload), len(newPayload), modifiedFields, curLat, curLon))

	responseBytes, err := buildWlocResponse(newPayload)
	if err != nil {
		logEvent(fmt.Sprintf("%v, passing through", err))
		return req, nil
	}

	resp := &http.Response{
		Request:       req,
		StatusCode:    http.StatusOK,
		Status:        "200 OK",
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        make(http.Header),
		Body:          io.NopCloser(bytes.NewReader(responseBytes)),
		ContentLength: int64(len(responseBytes)),
	}
	resp.Header.Set("Content-Type", "application/octet-stream")
	logEvent(fmt.Sprintf("Response sent 200 OK respLen=%d wifiCount=%d", len(responseBytes), wifiCount))
	return req, resp
}

// buildWlocResponse frames a protobuf payload as a /clls/wloc response body.
// The length field is only 16 bits, so larger payloads are rejected rather
// than silently truncated into a corrupt response.
func buildWlocResponse(payload []byte) ([]byte, error) {
	if len(payload) > math.MaxUint16 {
		return nil, fmt.Errorf("response payload %d B exceeds u16 length field", len(payload))
	}
	out := make([]byte, 0, len(wlocResponseHeader)+2+len(payload))
	out = append(out, wlocResponseHeader...)
	out = binary.BigEndian.AppendUint16(out, uint16(len(payload)))
	return append(out, payload...), nil
}

func generateCA() (certPEM, keyPEM []byte, err error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}

	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization:  []string{"Location Spoofer"},
			Country:       []string{"US"},
			Province:      []string{""},
			Locality:      []string{""},
			StreetAddress: []string{""},
			PostalCode:    []string{""},
			CommonName:    "Location Spoofer CA",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, nil, err
	}

	certPEM = pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})

	privateKeyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, nil, err
	}

	keyPEM = pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: privateKeyDER,
	})

	return certPEM, keyPEM, nil
}

func parseCA(caCert, caKey []byte) (*tls.Certificate, error) {
	parsedCert, err := tls.X509KeyPair(caCert, caKey)
	if err != nil {
		return nil, err
	}
	if parsedCert.Leaf, err = x509.ParseCertificate(parsedCert.Certificate[0]); err != nil {
		return nil, err
	}
	return &parsedCert, nil
}

func main() {}

// rewriteAppleWLocCoords 在 AppleWLoc 原始 wire bytes 上扫描所有 WifiDevices(tag=2 LEN),
// 对每个 WifiDevice 递归调用 rewriteWifiDevice 把 lat/lon 改成 spoof 坐标。
// 其他顶层字段(NumCellResults/CellTowerResponse/DeviceType/未知 tag 等)wire 字节级原样保留。
// 解析失败原样返回(透传),由调用方继续走 Apple 真响应路径。
func rewriteAppleWLocCoords(payload []byte, lat, lon int64) ([]byte, int) {
	out := make([]byte, 0, len(payload))
	modified := 0
	b := payload
	for len(b) > 0 {
		num, typ, tagLen := protowire.ConsumeTag(b)
		if tagLen < 0 {
			return payload, modified
		}
		if num == 2 && typ == protowire.BytesType {
			wdBytes, valLen := protowire.ConsumeBytes(b[tagLen:])
			if valLen < 0 {
				return payload, modified
			}
			newWd, sub := rewriteWifiDevice(wdBytes, lat, lon)
			modified += sub
			out = protowire.AppendTag(out, 2, protowire.BytesType)
			out = protowire.AppendBytes(out, newWd)
			b = b[tagLen+valLen:]
		} else {
			n := protowire.ConsumeFieldValue(num, typ, b[tagLen:])
			if n < 0 {
				return payload, modified
			}
			out = append(out, b[:tagLen+n]...)
			b = b[tagLen+n:]
		}
	}
	return out, modified
}

// rewriteWifiDevice 在 WifiDevice wire bytes 上找 Location(tag=2 LEN)子消息执行替换。
// 若 WifiDevice 不含 Location(请求侧通常如此),则在末尾注入完整新 Location(只含 lat/lon),
// 匹配 upstream Unmarshal 路径的 `if device.Location == nil { device.Location = &pb.Location{} }` 语义。
// 其他字段(Bssid 等)wire 字节级保留。
func rewriteWifiDevice(wd []byte, lat, lon int64) ([]byte, int) {
	out := make([]byte, 0, len(wd)+24)
	modified := 0
	locationSeen := false
	b := wd
	for len(b) > 0 {
		num, typ, tagLen := protowire.ConsumeTag(b)
		if tagLen < 0 {
			return wd, modified
		}
		if num == 2 && typ == protowire.BytesType {
			locationSeen = true
			locBytes, valLen := protowire.ConsumeBytes(b[tagLen:])
			if valLen < 0 {
				return wd, modified
			}
			newLoc, sub := rewriteLocation(locBytes, lat, lon)
			modified += sub
			out = protowire.AppendTag(out, 2, protowire.BytesType)
			out = protowire.AppendBytes(out, newLoc)
			b = b[tagLen+valLen:]
		} else {
			n := protowire.ConsumeFieldValue(num, typ, b[tagLen:])
			if n < 0 {
				return wd, modified
			}
			out = append(out, b[:tagLen+n]...)
			b = b[tagLen+n:]
		}
	}
	if !locationSeen {
		var loc []byte
		loc = protowire.AppendTag(loc, 1, protowire.VarintType)
		loc = protowire.AppendVarint(loc, uint64(lat))
		loc = protowire.AppendTag(loc, 2, protowire.VarintType)
		loc = protowire.AppendVarint(loc, uint64(lon))
		out = protowire.AppendTag(out, 2, protowire.BytesType)
		out = protowire.AppendBytes(out, loc)
		modified += 2
	}
	return out, modified
}

// rewriteLocation 在 Location wire bytes 上替换 Latitude(tag=1 varint)和 Longitude(tag=2 varint)。
// 缺失字段会被注入。其他字段(HorizontalAccuracy/Altitude/未知 tag 等)wire 字节级原样保留。
// int64 转 varint 用 uint64 重解释(protobuf int64 varint 编码规则)。
func rewriteLocation(loc []byte, lat, lon int64) ([]byte, int) {
	out := make([]byte, 0, len(loc)+20)
	modified := 0
	latSeen := false
	lonSeen := false
	b := loc
	for len(b) > 0 {
		num, typ, tagLen := protowire.ConsumeTag(b)
		if tagLen < 0 {
			return loc, modified
		}
		if num == 1 && typ == protowire.VarintType {
			latSeen = true
			_, valLen := protowire.ConsumeVarint(b[tagLen:])
			if valLen < 0 {
				return loc, modified
			}
			out = protowire.AppendTag(out, 1, protowire.VarintType)
			out = protowire.AppendVarint(out, uint64(lat))
			b = b[tagLen+valLen:]
			modified++
		} else if num == 2 && typ == protowire.VarintType {
			lonSeen = true
			_, valLen := protowire.ConsumeVarint(b[tagLen:])
			if valLen < 0 {
				return loc, modified
			}
			out = protowire.AppendTag(out, 2, protowire.VarintType)
			out = protowire.AppendVarint(out, uint64(lon))
			b = b[tagLen+valLen:]
			modified++
		} else {
			n := protowire.ConsumeFieldValue(num, typ, b[tagLen:])
			if n < 0 {
				return loc, modified
			}
			out = append(out, b[:tagLen+n]...)
			b = b[tagLen+n:]
		}
	}
	if !latSeen {
		out = protowire.AppendTag(out, 1, protowire.VarintType)
		out = protowire.AppendVarint(out, uint64(lat))
		modified++
	}
	if !lonSeen {
		out = protowire.AppendTag(out, 2, protowire.VarintType)
		out = protowire.AppendVarint(out, uint64(lon))
		modified++
	}
	return out, modified
}

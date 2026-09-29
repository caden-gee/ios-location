package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"strconv"
)

// ArpcRequest is the envelope locationd wraps around the protobuf payload it
// POSTs to gs-loc.apple.com/clls/wloc. Layout (all integers big-endian):
//
//	u16 version | pstr locale | pstr appIdentifier | pstr osVersion |
//	u32 functionId | u32 payloadLen | payload
//
// where pstr is a u16 length followed by that many bytes. Mirrors the
// reference implementation in acheong08/apple-corelocation-experiments.
type ArpcRequest struct {
	Version       string
	Locale        string
	AppIdentifier string
	OsVersion     string
	FunctionId    int
	Payload       []byte
}

func CoordFromInt(n int64) float64 {
	return float64(n) * math.Pow10(-8)
}

func IntFromCoord(coord float64) int64 {
	return int64(math.Round(coord * math.Pow10(8)))
}

func readPascalString(r io.Reader) (string, error) {
	var length uint16
	if err := binary.Read(r, binary.BigEndian, &length); err != nil {
		return "", err
	}
	str := make([]byte, length)
	if _, err := io.ReadFull(r, str); err != nil {
		return "", fmt.Errorf("pascal string of length %d: %w", length, err)
	}
	return string(str), nil
}

func ArpcDeserialize(data []byte) (*ArpcRequest, error) {
	r := bytes.NewReader(data)

	var version uint16
	if err := binary.Read(r, binary.BigEndian, &version); err != nil {
		return nil, fmt.Errorf("version: %w", err)
	}
	locale, err := readPascalString(r)
	if err != nil {
		return nil, fmt.Errorf("locale: %w", err)
	}
	appIdentifier, err := readPascalString(r)
	if err != nil {
		return nil, fmt.Errorf("app identifier: %w", err)
	}
	osVersion, err := readPascalString(r)
	if err != nil {
		return nil, fmt.Errorf("os version: %w", err)
	}
	var functionId uint32
	if err := binary.Read(r, binary.BigEndian, &functionId); err != nil {
		return nil, fmt.Errorf("function id: %w", err)
	}
	var payloadLen uint32
	if err := binary.Read(r, binary.BigEndian, &payloadLen); err != nil {
		return nil, fmt.Errorf("payload length: %w", err)
	}
	if int64(payloadLen) > int64(r.Len()) {
		return nil, fmt.Errorf("payload length %d exceeds remaining buffer size %d", payloadLen, r.Len())
	}
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, fmt.Errorf("payload: %w", err)
	}

	return &ArpcRequest{
		Version:       strconv.Itoa(int(version)),
		Locale:        locale,
		AppIdentifier: appIdentifier,
		OsVersion:     osVersion,
		FunctionId:    int(functionId),
		Payload:       payload,
	}, nil
}

func ArpcSerialize(arpc *ArpcRequest) ([]byte, error) {
	version, err := strconv.Atoi(arpc.Version)
	if err != nil {
		return nil, fmt.Errorf("version: %w", err)
	}
	buf := binary.BigEndian.AppendUint16(nil, uint16(version))
	for _, s := range []string{arpc.Locale, arpc.AppIdentifier, arpc.OsVersion} {
		if len(s) > math.MaxUint16 {
			return nil, fmt.Errorf("pascal string too long: %d bytes", len(s))
		}
		buf = binary.BigEndian.AppendUint16(buf, uint16(len(s)))
		buf = append(buf, s...)
	}
	buf = binary.BigEndian.AppendUint32(buf, uint32(arpc.FunctionId))
	buf = binary.BigEndian.AppendUint32(buf, uint32(len(arpc.Payload)))
	buf = append(buf, arpc.Payload...)
	return buf, nil
}

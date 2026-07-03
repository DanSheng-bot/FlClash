//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"core/platform"
	t "core/tun"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sync/semaphore"
)

const stopTrace = "[STOP-TRACE]"

var eventListener unsafe.Pointer

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit *semaphore.Weighted
}

func (th *TunHandler) start(fd int, stack, address, dns string) {
	runLock.Lock()
	defer runLock.Unlock()
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	th.initHook()
	tunListener := t.Start(fd, stack, address, dns)
	if tunListener != nil {
		log.Infoln("TUN address: %v", tunListener.Address())
		th.listener = tunListener
		return
	}
	th.clear(false)
}

func (th *TunHandler) close(trace bool) {
	startedAt := time.Now()
	if trace {
		log.Infoln("%s waiting for TUN callback permits", stopTrace)
	}
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	if trace {
		log.Infoln(
			"%s TUN callback permits acquired in %dms",
			stopTrace,
			time.Since(startedAt).Milliseconds(),
		)
	}
	th.clear(trace)
	if trace {
		log.Infoln(
			"%s TunHandler.close completed in %dms",
			stopTrace,
			time.Since(startedAt).Milliseconds(),
		)
	}
}

func (th *TunHandler) clear(trace bool) {
	th.removeHook()
	if th.listener != nil {
		listenerStartedAt := time.Now()
		if trace {
			log.Infoln("%s TUN listener close begin", stopTrace)
		}
		_ = th.listener.Close()
		if trace {
			log.Infoln(
				"%s TUN listener close completed in %dms",
				stopTrace,
				time.Since(listenerStartedAt).Milliseconds(),
			)
		}
	}
	if th.callback != nil {
		callbackStartedAt := time.Now()
		if trace {
			log.Infoln("%s TUN callback release begin", stopTrace)
		}
		releaseObject(th.callback)
		if trace {
			log.Infoln(
				"%s TUN callback release completed in %dms",
				stopTrace,
				time.Since(callbackStartedAt).Milliseconds(),
			)
		}
	}
	th.callback = nil
	th.listener = nil
}

func (th *TunHandler) handleProtect(fd int) {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil {
		return
	}

	protect(th.callback, fd)
}

func (th *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return resolveProcess(th.callback, protocol, source.String(), target.String(), uid)
}

func (th *TunHandler) initHook() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		return conn.Control(func(fd uintptr) {
			tunHandler.handleProtect(int(fd))
		})
	}
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		return tunHandler.handleResolveProcess(src, dst), nil
	}
}

func (th *TunHandler) removeHook() {
	dialer.DefaultSocketHook = nil
	process.DefaultPackageNameResolver = nil
}

var (
	tunLock    sync.Mutex
	errBlocked = errors.New("blocked")
	tunHandler *TunHandler
)

func handleStopTun(trace bool) {
	startedAt := time.Now()
	if trace {
		log.Infoln("%s waiting for tunLock", stopTrace)
	}
	tunLock.Lock()
	defer tunLock.Unlock()
	if trace {
		log.Infoln(
			"%s tunLock acquired in %dms",
			stopTrace,
			time.Since(startedAt).Milliseconds(),
		)
	}
	if tunHandler != nil {
		tunHandler.close(trace)
	} else if trace {
		log.Infoln("%s no active TunHandler", stopTrace)
	}
}

func handleStartTun(callback unsafe.Pointer, fd int, stack, address, dns string) {
	handleStopTun(false)
	tunLock.Lock()
	defer tunLock.Unlock()
	if fd != 0 {
		tunHandler = &TunHandler{
			callback: callback,
			limit:    semaphore.NewWeighted(4),
		}
		tunHandler.start(fd, stack, address, dns)
	}
	return
}

func (response MethodResponse) send() {
	data, err := response.JSON()
	if err != nil {
		return
	}
	invokeResult(response.callback, string(data))
	releaseObject(response.callback)
}

func handlePlatformMethodCall(call *MethodCall, response MethodResponse) bool {
	switch call.Method {
	case updateDnsMethod:
		value := ""
		if !decodeMethodArguments(call, response, &value) {
			return true
		}
		handleUpdateDns(value)
		response.success(true)
		return true
	}
	return false
}

//export invokeMethod
func invokeMethod(callback unsafe.Pointer, paramsChar *C.char) {
	params := takeCString(paramsChar)
	call := &MethodCall{}
	err := json.Unmarshal([]byte(params), call)
	if err != nil {
		response := MethodResponse{callback: callback}
		response.failure("invalid_method_call", err.Error(), nil)
		return
	}
	response := MethodResponse{
		ID:       call.ID,
		callback: callback,
	}
	go handleMethodCall(call, response)
}

//export startTUN
func startTUN(callback unsafe.Pointer, fd C.int, stackChar, addressChar, dnsChar *C.char) bool {
	handleStartTun(callback, int(fd), takeCString(stackChar), takeCString(addressChar), takeCString(dnsChar))
	if !isRunning {
		handleStartListener()
	} else {
		handleResetConnections()
	}
	return true
}

//export quickSetup
func quickSetup(callback unsafe.Pointer, initParamsChar *C.char, setupParamsChar *C.char) {
	go func() {
		defer releaseObject(callback)
		initParamsString := takeCString(initParamsChar)
		setupParamsString := takeCString(setupParamsChar)
		initParams := InitParams{}
		if err := json.Unmarshal([]byte(initParamsString), &initParams); err != nil || !handleInitClash(&initParams) {
			invokeResult(callback, "init failed")
			return
		}
		isRunning = true
		setupParams := defaultSetupParams()
		if err := UnmarshalJson([]byte(setupParamsString), setupParams); err != nil {
			invokeResult(callback, err.Error())
			return
		}
		message := handleSetupConfig(setupParams)
		invokeResult(callback, message)
	}()
}

//export setEventListener
func setEventListener(listener unsafe.Pointer) {
	if eventListener != nil || listener == nil {
		releaseObject(eventListener)
	}
	eventListener = listener
}

//export getTotalTraffic
func getTotalTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(marshalResult(handleGetTotalTraffic(onlyStatisticsProxy)))
}

//export getTraffic
func getTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(marshalResult(handleGetTraffic(onlyStatisticsProxy)))
}

func marshalResult(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		logError("Result marshal error: %v", err)
		return ""
	}
	return string(data)
}

func sendMessageBatch(messages []Message) {
	if eventListener == nil {
		return
	}
	call := MethodCall{
		Method:    messageMethod,
		Arguments: mustMarshalJSON(messages),
	}
	data, err := json.Marshal(call)
	if err != nil {
		return
	}
	invokeResult(eventListener, string(data))
}

//export stopTun
func stopTun() {
	startedAt := time.Now()
	log.Infoln("%s core stopTun begin isRunning=%t", stopTrace, isRunning)
	handleStopTun(true)
	log.Infoln(
		"%s core TUN stopped in %dms",
		stopTrace,
		time.Since(startedAt).Milliseconds(),
	)
	if isRunning {
		listenersStartedAt := time.Now()
		log.Infoln("%s core listener stop begin", stopTrace)
		handleStopListener()
		log.Infoln(
			"%s core listener stop completed in %dms",
			stopTrace,
			time.Since(listenersStartedAt).Milliseconds(),
		)
	}
	log.Infoln(
		"%s core stopTun completed in %dms",
		stopTrace,
		time.Since(startedAt).Milliseconds(),
	)
}

//export suspend
func suspend(suspended bool) {
	handleSuspend(suspended)
}

//export forceGC
func forceGC() {
	handleForceGC()
}

//export updateDns
func updateDns(s *C.char) {
	handleUpdateDns(takeCString(s))
}

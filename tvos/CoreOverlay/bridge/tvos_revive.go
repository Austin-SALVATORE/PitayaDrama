package main

/*
#include <stdlib.h>
*/
import "C"
import "duanjuapp/native/core"

// 火龙果短剧（tvOS 分支）自带的补丁，见 tvos/CoreOverlay/core/tvos_stream_revive.go。
// 返回的字符串由调用方用 DuanjuFree 释放。

//export DuanjuReviveStream
func DuanjuReviveStream() *C.char { return C.CString(core.ReviveNativeStream()) }

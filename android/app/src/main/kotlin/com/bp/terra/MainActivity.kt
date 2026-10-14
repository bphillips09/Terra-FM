package com.bp.terra

import com.ryanheise.audioservice.AudioServiceActivity

/** USB access lives in the terra_usb plugin (packages/terra_usb), so it works on every engine. */
class MainActivity : AudioServiceActivity()

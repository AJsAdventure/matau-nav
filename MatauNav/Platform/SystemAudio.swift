//  SystemAudio.swift
//  Best-effort check whether the Mac's audio output can actually be heard.
//
//  Why: the anchor-drag alarm is the last line of defence, and AVAudioPlayer
//  cannot bypass a muted / zero-volume output device on macOS (there is no
//  audio-session override like iOS's .playback). A Mac quietly muted at the
//  nav station would ring a silent alarm. This check lets the anchor watch
//  warn the crew AT ARMING TIME, when it's still cheap to fix.
//
//  Best-effort by design: some output devices expose no master mute/volume
//  control (multi-channel interfaces). Any query error reports "audible" —
//  a false "muted" warning would train the crew to ignore it.

#if os(macOS)
import CoreAudio

enum SystemAudio {

    /// True when the default output device is muted or its master volume is
    /// effectively zero. Returns false whenever the answer is unknowable.
    static var outputEffectivelySilent: Bool {
        guard let dev = defaultOutputDevice() else { return false }
        if boolProperty(dev, selector: kAudioDevicePropertyMute) == true { return true }
        // Master-element volume where supported, else channel 1 (most built-in
        // devices expose one or the other; if neither, assume audible).
        let volume = floatProperty(dev, selector: kAudioDevicePropertyVolumeScalar,
                                   element: kAudioObjectPropertyElementMain)
                  ?? floatProperty(dev, selector: kAudioDevicePropertyVolumeScalar, element: 1)
        if let v = volume, v < 0.03 { return true }
        return false
    }

    /// Force the default output device to be audible: unmute it and raise the
    /// master volume to at least `minVolume`. Best-effort — devices without a
    /// settable master control are left alone.
    ///
    /// Called every ~2 s while a LOUD alarm rings (from AlarmSiren.acquire).
    /// Rationale: iOS bypasses the mute switch for the drag alarm; on a Mac
    /// the only equivalent is refusing to stay muted. "Someone muted the Mac
    /// at the nav station" must not mean "no anchor alarm at 3 a.m." —
    /// deliberate silencing goes through Snooze, which is one click.
    static func ensureAudible(minVolume: Float32 = 0.7) {
        guard let dev = defaultOutputDevice() else { return }
        if boolProperty(dev, selector: kAudioDevicePropertyMute) == true {
            setUInt32Property(dev, selector: kAudioDevicePropertyMute,
                              element: kAudioObjectPropertyElementMain, value: 0)
        }
        let current = floatProperty(dev, selector: kAudioDevicePropertyVolumeScalar,
                                    element: kAudioObjectPropertyElementMain)
                   ?? floatProperty(dev, selector: kAudioDevicePropertyVolumeScalar, element: 1)
        if let v = current, v < minVolume {
            // Master element where supported, else channels 1+2.
            if !setFloatProperty(dev, selector: kAudioDevicePropertyVolumeScalar,
                                 element: kAudioObjectPropertyElementMain, value: minVolume) {
                _ = setFloatProperty(dev, selector: kAudioDevicePropertyVolumeScalar,
                                     element: 1, value: minVolume)
                _ = setFloatProperty(dev, selector: kAudioDevicePropertyVolumeScalar,
                                     element: 2, value: minVolume)
            }
        }
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &dev)
        return (err == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    private static func boolProperty(_ dev: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func floatProperty(_ dev: AudioObjectID, selector: AudioObjectPropertySelector,
                                      element: AudioObjectPropertyElement) -> Float32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  element)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setFloatProperty(_ dev: AudioObjectID, selector: AudioObjectPropertySelector,
                                         element: AudioObjectPropertyElement, value: Float32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  element)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    @discardableResult
    private static func setUInt32Property(_ dev: AudioObjectID, selector: AudioObjectPropertySelector,
                                          element: AudioObjectPropertyElement, value: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  element)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}
#endif

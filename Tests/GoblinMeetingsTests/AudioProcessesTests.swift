import CoreAudio
import Testing
@testable import GoblinMeetings

@Test func helpersNamedAfterAnotherAppBelongToTheAppThatLaunchedThem() throws {
    let dia = AudioClientApp.Running(bundleID: "company.thebrowser.dia", name: "Dia", pid: 100)
    let arc = AudioClientApp.Running(bundleID: "company.thebrowser.Browser", name: "Arc", pid: 200)
    let diaHost = audioProcess(10, pid: dia.pid, bundleID: dia.bundleID)
    let diaAudio = audioProcess(11, pid: 101, bundleID: "company.thebrowser.browser.helper", active: true)
    let diaRenderer = audioProcess(12, pid: 102, bundleID: "company.thebrowser.browser.helper.renderer")
    let arcAudio = audioProcess(13, pid: 201, bundleID: "company.thebrowser.Browser.helper", active: true)
    let arcShared = audioProcess(15, pid: 202, bundleID: "company.thebrowser.browser.helper", active: true)
    let orphan = audioProcess(14, pid: 301, bundleID: "company.thebrowser.browser.helper", active: true)
    let parents = [diaAudio.pid: dia.pid, diaRenderer.pid: dia.pid, arcAudio.pid: arc.pid, arcShared.pid: arc.pid, orphan.pid: 1]

    let groups = AudioClientApp.group([diaHost, diaAudio, diaRenderer, arcAudio, arcShared, orphan], running: [arc, dia]) {
        parents[$0]
    }

    let diaGroup = try #require(groups.first { $0.bundleID == dia.bundleID })
    #expect(diaGroup.pid == dia.pid)
    #expect(diaGroup.callApp?.name == "Dia")
    #expect(diaGroup.isUsingMicrophone && diaGroup.isPlayingAudio)
    #expect(diaGroup.processes.map(\.objectID) == [10, 11, 12])
    #expect(Set(groups.first { $0.bundleID == arc.bundleID }?.processes ?? []) == [arcAudio, arcShared])
    let unknownGroup = try #require(groups.first { $0.bundleID == "company.thebrowser.browser" })
    #expect(unknownGroup.processes == [orphan])
    #expect(unknownGroup.callApp == nil)
}

@Test func standardAudioHelpersStillResolveByBundlePrefix() throws {
    let chrome = AudioClientApp.Running(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 100)
    let helper = audioProcess(10, pid: 101, bundleID: "com.google.Chrome.helper.renderer", active: true)

    let groups = AudioClientApp.group([helper], running: [chrome]) { _ in
        Issue.record("Chrome's helper already matches by bundle prefix")
        return nil
    }

    let group = try #require(groups.first)
    #expect(group.bundleID == chrome.bundleID)
    #expect(group.pid == chrome.pid)
    #expect(group.processes == [helper])
}

private func audioProcess(_ id: AudioObjectID, pid: pid_t, bundleID: String, active: Bool = false) -> AudioProcess {
    AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningInput: active, isRunningOutput: active)
}

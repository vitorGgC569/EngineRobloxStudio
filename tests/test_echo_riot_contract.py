from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "games" / "echo-riot"


def sources() -> tuple[str, str, str, str]:
    config = (GAME / "src" / "shared" / "Config.lua").read_text(encoding="utf-8")
    world = (GAME / "src" / "server" / "World.lua").read_text(encoding="utf-8")
    server = (GAME / "src" / "server" / "init.server.lua").read_text(encoding="utf-8")
    client = (GAME / "src" / "client" / "init.client.lua").read_text(encoding="utf-8")
    return config, world, server, client


def test_echo_riot_world_and_hub_contract() -> None:
    config, world, server, client = sources()

    assert 'hub = {' in config
    assert 'stage = {' in config
    assert 'origin = Vector3.new(0, 0, -620)' in config
    assert 'plazaRadius = 74' in config
    assert 'radius = 92' in config
    assert 'podRadius = 66' in config
    assert 'spectatorRadius = 112' in config

    assert 'mode = "local"' in config
    assert 'stagePlaceId = 0' in config

    for token in (
        '"Hub"',
        '"JoinShow"',
        '"MicPractice"',
        '"StylePreview"',
        '"SessionLeaderboard"',
        '"HowToBoard"',
        '"QueueConsole"',
        '"HubStructureRing"',
        '"AcousticWall"',
        '"CeilingBeam"',
    ):
        assert token in world, token

    for token in (
        '"Stage"',
        '"MainStage"',
        '"PodBridge"',
        '"StageSpawn"',
        '"SpectatorFin"',
        '"MainBoard"',
    ):
        assert token in world, token

    ready_handler = server.split('Net.on("Ready"', 1)[1].split('Net.on("Sample"', 1)[0]
    assert 'ready[player]=true' not in ready_handler
    assert 'EchoClientReady' in ready_handler

    assert 'local function joinShow(player:Player,source:string)' in server
    assert 'world.portalPrompt.Triggered:Connect' in server
    assert 'joinShow(player,"portal")' in server
    assert 'Net.on("Join"' in server
    assert 'joinShow(player,"hud")' in server
    assert 'setStageState(player,#queued+1,source)' in server

    assert 'returnEveryoneToHub()' in server
    assert 'Net.on("Leave"' in server
    assert 'setHubState(player,"leave_button")' in server
    assert 'player:SetAttribute("EchoZone","HUB")' in server
    assert 'player:SetAttribute("EchoZone","STAGE")' in server

    assert 'hubGuide.Visible=not onStage' in client
    assert 'hubEnterButton.Name="EnterShowButton"' in client
    assert 'Net.send("Join",{})' in client
    assert 'leaveButton.Text="LEAVE SHOW · L"' in client
    assert 'Net.send("Leave",{})' in client
    assert 'camera.CameraType=Enum.CameraType.Custom' in client
    assert 'camera.CameraType=Enum.CameraType.Scriptable' in client

    assert 'EchoPracticeMode' in client
    assert 'EchoStyleHighlight' in client


def test_echo_riot_scoring_is_server_bounded_and_streamed() -> None:
    config, _world, server, client = sources()

    assert 'Sample={dir="c2s",rate=14}' in server
    assert 'Sample={dir="c2s",rate=14}' in client
    assert 'token~=buffer.token' in server
    assert 'seq<=buffer.lastSeq' in server
    assert '#buffer.samples<64' in server
    assert 'source~="microphone" and source~="practice"' in server
    assert 'answerToken=("%d:%d:%08x")' in server

    # The client streams bounded scalar observations instead of trusting a full
    # waveform array uploaded only at submit time.
    assert 'Net.send("Sample",{' in client
    assert 'value=level' in client
    submit_slice = client.split('Net.send("Submit",{', 1)[1].split('})', 1)[0]
    assert 'samples=' not in submit_slice
    assert 'token=token' in submit_slice

    # Practice is useful for Studio/accessibility but never contaminates the
    # competitive session leaderboard.
    assert 'if source=="practice" then' in server
    assert 'value=math.min(value,65)' in server
    assert 'local competitiveValue=source=="practice" and 0 or value' in server
    assert 'sessionScores[player]=(sessionScores[player] or 0)+competitiveValue' in server

    # DOUBLE TROUBLE must mean double, not a cosmetic modifier.
    assert 'value=value*2' in server
    assert 'Your round score counts twice.' in config


def test_echo_riot_round_lifecycle_is_fail_closed() -> None:
    config, _world, server, client = sources()

    for key in (
        'boardingSeconds = 5',
        'countdownSeconds = 2.5',
        'listenSeconds = 2.8',
        'answerSeconds = 3.6',
        'revealSeconds = 3.0',
        'intermissionSeconds = 1.5',
    ):
        assert key in config

    assert 'activeParticipants(participants)' in server
    assert 'if #active<1 then' in server
    assert 'aborted=true' in server
    assert 'setPhase("RESULTS",{aborted=true' in server
    assert 'returnEveryoneToHub()' in server

    # Client must expose current timing and an explicit escape hatch.
    assert 'timerText.Text=("%.1fs")' in client
    assert 'leaveButton.Activated:Connect(requestLeave)' in client
    assert 'Enum.KeyCode.L' in client

    # A long-dead copy of the initial world builder should never come back into
    # the gameplay server; World.lua owns geometry now.
    assert 'local function buildWorld()' not in server
    assert 'local function part(parent:Instance' not in server


def test_echo_riot_mobile_layout_has_explicit_phone_mode() -> None:
    _config, _world, _server, client = sources()

    assert 'local phone=width<560' in client
    assert 'local short=height<680' in client
    assert 'local showBoard=onStage and (currentPhase=="REVEAL" or currentPhase=="RESULTS")' in client
    assert 'board.Visible=showBoard and not narrow' in client
    assert 'if phone then' in client
    assert 'chaos.Visible=false' in client

    # Information hierarchy: leaderboard is contextual rather than occupying a
    # quarter of the screen during listen/answer gameplay.
    assert 'currentPhase=="REVEAL" or currentPhase=="RESULTS"' in client


def test_echo_riot_rojo_project_is_well_formed() -> None:
    payload = json.loads((GAME / "default.project.json").read_text(encoding="utf-8"))
    assert payload["name"] == "echo-riot"
    assert payload["tree"]["ReplicatedStorage"]["Forge"]["$path"] == "../../forge/luau/Forge"
    assert payload["tree"]["ServerScriptService"]["EchoRiot"]["$path"] == "src/server"
    assert payload["tree"]["StarterPlayer"]["StarterPlayerScripts"]["EchoRiot"]["$path"] == "src/client"


def test_echo_riot_hub_prompts_use_validated_client_actions() -> None:
    _config, _world, server, client = sources()

    # These prompts are client interactions; server-only Triggered handlers make
    # synthetic/client-side prompt activation non-replicating and untestable.
    assert 'HubAction={dir="c2s",rate=4,shape={action="string"}}' in server
    assert 'HubAction={dir="c2s",rate=4,shape={action="string"}}' in client
    assert 'Net.on("HubAction"' in server
    assert 'withinPromptRange(player,world.practicePrompt)' in server
    assert 'withinPromptRange(player,world.stylePrompt)' in server
    assert 'world.practicePrompt.Triggered:Connect' not in server
    assert 'world.stylePrompt.Triggered:Connect' not in server

    assert 'micPrompt.Triggered:Connect' in client
    assert 'stylePrompt.Triggered:Connect' in client
    assert 'Net.send("HubAction",{action="practice_toggle"})' in client
    assert 'Net.send("HubAction",{action="cycle_style"})' in client


def test_echo_riot_hub_keyboard_fallback_is_server_validated() -> None:
    _config, _world, server, client = sources()

    assert 'Enum.KeyCode.M' in client
    assert 'Net.send("HubAction",{action="practice_toggle"})' in client
    assert 'Enum.KeyCode.C' in client
    assert 'Net.send("HubAction",{action="cycle_style"})' in client
    assert 'withinPromptRange(player,world.practicePrompt)' in server
    assert 'withinPromptRange(player,world.stylePrompt)' in server


def test_echo_riot_style_deck_changes_assigned_stage_pod() -> None:
    _config, world, server, _client = sources()

    assert 'podAccents=podAccents' in world
    assert 'podAccents=stage.podAccents' in world
    assert 'local styleIndex=tonumber(player:GetAttribute("EchoStyleIndex")) or 1' in server
    assert 'local style=Config.styles[math.clamp(styleIndex,1,#Config.styles)]' in server
    assert 'local podAccent=world.podAccents and world.podAccents[podIndex]' in server
    assert 'podAccent.Color=style.color' in server

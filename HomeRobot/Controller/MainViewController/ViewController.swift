//
//  ViewController.swift
//  Robotty
//
//  Created by Ferdinand Lösch on 25/10/2019.
//  Copyright © 2019 Ferdinand Lösch. All rights reserved.
//
import ARKit
import ARNavigationKit
import CoreLocation
import UIKit

class ViewController: UIViewController, ARSessionDelegate,
    CLLocationManagerDelegate, MapListDelegate,
    TouchDriveDelegate {
    enum RobotConnectionState {
        case disconnected
        case wifi
        case plug
    }

    enum driveState {
        case getWaypoints
        case calculatePath
        case waiting
        case getPoint
        case driveToTarget
        case reachTarget
    }

    var botConnectionState: RobotConnectionState = .disconnected {
        didSet {
            if oldValue == botConnectionState { return }

            if botConnectionState == .disconnected {
                botModeButton.isUserInteractionEnabled = false
                botModeButton.setBackgroundImage(UIImage(named: "bot.png"), for: .normal)
                killRobotSlider.isHidden = true
            } else if botConnectionState == .wifi {
                print(" >>> Connected WiFi")
                botModeButton.isUserInteractionEnabled = true
                botModeButton.setBackgroundImage(UIImage(named: "bot-wifi.png"), for: .normal)
                killRobotSlider.isHidden = false

            } else if botConnectionState == .plug {
                killRobotSlider.isHidden = true
                botModeButton.isUserInteractionEnabled = true
                botModeButton.setBackgroundImage(UIImage(named: "bot-plug.png"), for: .normal)
            }
        }
    }

    enum BotInteractionState {
        case none
        case addShapes
        case addWaypoints
        case drivingControls
    }

    var interactionState: BotInteractionState = .none {
        didSet {
            if interactionState == .drivingControls {
                showDrivingView()
            } else if oldValue == .drivingControls {
                hideDrivingView()
            } else if interactionState == .addWaypoints {
                showStatus("Tap to add points")
            }
        }
    }

    enum MappingState {
        case none
        case localizing
        case creatingMap
    }

    var mappingState: MappingState = .none {
        didSet {
            // reset this if we leave .localizing
            hasFoundMapOnce = false
        }
    }

    var hasFoundMapOnce = false

    var trackingStarted = false

    @IBOutlet var showMapListButton: UIButton!
    @IBOutlet var doneMappingButton: UIButton!
    @IBOutlet var botModeButton: UIButton!
    @IBOutlet var statusLabel: UILabel!
    @IBOutlet var robotStatusLabel: UILabel!
    @IBOutlet var killRobotSlider: MMSlidingButton!

    var sceneView: ARSCNView!
    var scene: SCNScene!
    let defaultConfiguration = ARWorldTrackingConfiguration()

    let augmentedRealitySession = ARSession()

    var voxelMap = ARNavigationKit(VoxelGridCellSize: 0.1)

    var voxleRootNode = SCNNode()

    var planesVizAnchors = [ARAnchor]()
    var planesVizNodes = [UUID: SCNNode]()
    var planeDetection = true

    var shapeManager: ShapeManager!

    var locationManager: CLLocationManager!
    private var lastLocation: CLLocation?

    private var currentMapId: String!
    private var lastScreenshot: UIImage!

    var path: [SCNVector3] = []

    var currentDriveState: driveState = .getWaypoints

    // Wifi stuff
    @IBOutlet var connectionsLabel: UILabel!
    private var wifiDevice: WifiServiceManager!

    // Robot
    var robot: RMCoreRobotRomo3!

    var driveView: TouchDriveView!

    let notSyncedMessage = "You must first sync positions. Create a map, and load the map on both robot and controller devices."

    override func viewDidLoad() {
        super.viewDidLoad()

        TestRobotMessages()

        sceneView = ARSCNView(frame: view.frame)
        sceneView.session = augmentedRealitySession
        sceneView.delegate = self
        sceneView.autoenablesDefaultLighting = true
        sceneView.isPlaying = true

        voxelMap.arNavigationKitDelegate = self

        scene = SCNScene()
        sceneView.scene = scene

        shapeManager = ShapeManager(scene: scene, view: sceneView)

        view.insertSubview(sceneView, at: 0)

        UIApplication.shared.isIdleTimerDisabled = true

        RMCore.setDelegate(self)

        killRobotSlider.delegate = self

        showStatus("Hi")

        // Location
        locationManager = CLLocationManager()
        locationManager.requestWhenInUseAuthorization()

        if CLLocationManager.locationServicesEnabled() {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.startUpdatingLocation()
        }

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.isEnabled = true
        sceneView.addGestureRecognizer(tapRecognizer)

        wifiDevice = WifiServiceManager()
        wifiDevice.delegate = self

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.startPeerTimer()
        }
    }

    // Initialize view and scene
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !isSessionRunning {
            configureSession()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Pause the view's session
        // scnView.session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sceneView.frame = view.bounds

        if let dv = self.driveView {
            let size = dv.powerView.bounds.size.width
            let h = view.bounds.size.height
            let w = view.bounds.size.width
            dv.powerView.center = CGPoint(x: size * 0.5, y: h - size * 0.55)
            dv.steeringView.center = CGPoint(x: w - size * 0.5, y: h - size * 0.55)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: ARKit

    var isSessionRunning = false

    func configureSession() {
        isSessionRunning = true

        // Create a session configuration
        defaultConfiguration.worldAlignment = ARWorldTrackingConfiguration.WorldAlignment.gravity // TODO: Maybe not heading?

        if planeDetection {
            if #available(iOS 11.3, *) {
                defaultConfiguration.planeDetection = [.horizontal, .vertical]
            } else {
                defaultConfiguration.planeDetection = [.horizontal]
            }
        } else {
            for (_, node) in planesVizNodes {
                node.removeFromParentNode()
            }
            for anchor in planesVizAnchors { // remove anchors because in iOS versions <11.3, the anchors are not automatically removed when plane detection is turned off.
                sceneView.session.remove(anchor: anchor)
            }
            planesVizNodes.removeAll()
            defaultConfiguration.planeDetection = []
        }

        // Run the view's session
        augmentedRealitySession.run(defaultConfiguration)

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let currentFrame = self.augmentedRealitySession.currentFrame,
                let featurePointsArray = currentFrame.rawFeaturePoints?.points else { return }
            self.voxelMap.addVoxels(featurePointsArray)
        }
    }

    // MARK: - MapListDelegate

    func newMapTapped() {
        doneMappingButton.isHidden = false
        mappingState = .creatingMap

        // creating new map, remove old shapes.
        shapeManager.clearShapes()

        // Take a photo when new map is created for the thumbnail
        lastScreenshot = sceneView.snapshot()
    }

    func mapLoaded(map: Map) {
        showStatus("Map Loaded. Look Around")
        mappingState = .localizing
        currentMapId = map.mapId
        let configuration = defaultConfiguration // this app's standard world tracking settings
        configuration.initialWorldMap = map.worldMap
        augmentedRealitySession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - UI Actions

    @IBAction func botModeButtonTapped() {
        if botConnectionState == .disconnected {
            let msg = "No Bot connected. Make sure bot is plugged in and devices are on the same WiFi network."
            showAlert(msg)
            _ = AudioPlayer.shared.play(.sorry_try_again)

        } else if botConnectionState == .plug {
            // do nothing for robot mode
            return
        }

        let alert = UIAlertController(title: "", message: "Select Bot Mode", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Drive Controls", style: .default, handler: { _ in
            self.interactionState = .drivingControls
            _ = AudioPlayer.shared.play(.engaged)
        }))

        alert.addAction(UIAlertAction(title: "Send Map To Robot", style: .default, handler: { _ in
            self.sendMap()

        }))

        alert.addAction(UIAlertAction(title: "Waypoint Mode", style: .default, handler: { _ in

            if self.areClientsSynced {
                _ = AudioPlayer.shared.play(.auto_pilot_activated)
                self.interactionState = .addWaypoints
            } else {
                self.showAlert(self.notSyncedMessage)
                _ = AudioPlayer.shared.play(.sorry_try_again)
            }

        }))

        if interactionState == .addWaypoints, pendingCommands.count > 0 {
            alert.addAction(UIAlertAction(title: "Send Waypoints", style: .default, handler: { _ in
                self.sendAllPendingMarkers(nil)

            }))
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        if let popoverPresentationController = alert.popoverPresentationController,
            let view = self.botModeButton {
            popoverPresentationController.sourceView = view
            popoverPresentationController.sourceRect = view.bounds
        }

        present(alert, animated: true, completion: nil)
    }

    @objc func handleTap(sender: UITapGestureRecognizer) {
        if interactionState == .addWaypoints {
            if !areClientsSynced {
                showAlert(notSyncedMessage)
                return
            }

            let tapLocation = sender.location(in: sceneView)

            let hitTestResults = sceneView.hitTest(tapLocation, types: .featurePoint)

            for result in hitTestResults {
                let pos = result.worldTransform.columns.3
                addDriveToMarker(SCNVector3(pos.x, pos.y + 0.06, pos.z))
            }
        }
    }

    @IBAction func showMapsTapped() {
        showMapList()
        _ = AudioPlayer.shared.play(.accessing_archives)
    }

    func showMapList() {
        let vc = MapController()
        vc.mapDelegate = self

        vc.modalPresentationStyle = UIModalPresentationStyle.popover

        let popOverController = vc.popoverPresentationController
        popOverController!.delegate = vc

        popOverController!.sourceView = view
        let frame = showMapListButton.frame

        popOverController!.sourceRect = CGRect(x: frame.origin.x,
                                               y: frame.origin.y - 20,
                                               width: frame.size.width,
                                               height: frame.size.height)

        popOverController?.permittedArrowDirections = .any

        present(vc, animated: true, completion: nil)
    }

    func showAlert(_ msg: String, title: String = "Alert!") {
        let alertController = UIAlertController(title: title,
                                                message: msg,
                                                preferredStyle: UIAlertController.Style.alert)

        let okAction = UIAlertAction(title: "OK", style: UIAlertAction.Style.default) {
            (_: UIAlertAction) -> Void in
        }

        alertController.addAction(okAction)

        present(alertController, animated: true, completion: nil)
    }

    // MARK: - Persistence: Saving and Loading

    lazy var mapSaveURL: URL = {
        do {
            let uuid = UUID().uuidString
            var list = UserDefaults.standard
                .array(forKey: "map") as? [String] ?? [String]()
            list.append("\(uuid)_map.arexperience")
            UserDefaults.standard.set(list, forKey: "map")
            return try FileManager.default
                .url(for: .documentDirectory,
                     in: .userDomainMask,
                     appropriateFor: nil,
                     create: true)
                .appendingPathComponent("\(uuid)_map.arexperience")
        } catch {
            fatalError("Can't get file save URL: \(error.localizedDescription)")
        }
    }()

    @IBAction func doneMappingTapped() {
        doneMappingButton.isHidden = true

        sceneView.session.getCurrentWorldMap { worldMap, error in
            guard let map = worldMap
            else { self.showAlert(title: "Can't get current world map", message: error!.localizedDescription); return }

            // Add a snapshot image indicating where the map was captured.
            guard let snapshotAnchor = SnapshotAnchor(capturing: self.sceneView)
            else { fatalError("Can't take snapshot") }
            map.anchors.append(snapshotAnchor)

            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                try data.write(to: self.mapSaveURL, options: [.atomic])

            } catch {
                fatalError("Can't save map: \(error.localizedDescription)")
            }
        }
    }

    func showStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }

    // MARK:

    func onStatus(isReady: Bool) {
        if isReady {
            // just localized redraw the shapes
            shapeManager.drawView(parent: scene.rootNode)

            if mappingState == .creatingMap {
                showStatus("Tap anywhere to add Shapes")
            } else if mappingState == .localizing {
                hasFoundMapOnce = true
                showStatus("Map Found!")
            }

        } else {
            // just lost localization
            if mappingState == .creatingMap {
                showStatus("Map Lost")
            }
        }
    }

    // MARK: - ARSessionDelegate

    // Provides a newly captured camera image and accompanying AR information to the delegate.
    func session(_: ARSession, didUpdate _: ARFrame) {}

    // Informs the delegate of changes to the quality of ARKit's device position tracking.
    func session(_: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var status = "Loading.."
        switch camera.trackingState {
        case ARCamera.TrackingState.notAvailable:
            status = "Not available"
            onStatus(isReady: false)
        case ARCamera.TrackingState.limited(.excessiveMotion):
            status = "Excessive Motion."
            onStatus(isReady: false)
        case ARCamera.TrackingState.limited(.insufficientFeatures):
            status = "Insufficient features"
            onStatus(isReady: false)
        case ARCamera.TrackingState.limited(.initializing):
            status = "Initializing"
            _ = AudioPlayer.shared.play(.processing)
        case ARCamera.TrackingState.limited(.relocalizing):
            status = "Relocalizing"
            _ = AudioPlayer.shared.play(.verifying)
        case ARCamera.TrackingState.normal:
            if !trackingStarted {
                trackingStarted = true
                // newMapButton.isEnabled = true
            }
            status = "Ready"
            _ = AudioPlayer.shared.play(.system_stable)
            onStatus(isReady: true)
        }
        showStatus(status)
    }

    func session(_: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            planesVizAnchors.append(anchor)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func base64encode(_ image: UIImage) -> String {
        let img = image.cropToSquare()!.resizeImage(48, opaque: true)

        return img.jpegData(compressionQuality: 0.2)!.base64EncodedString()
    }

    // MARK: - Wifi

    // Pyramid that will display over the robot or phone
    var peerNode: SCNNode!

    func sendMessage(_ message: RobotMessage) {
        guard let jsonData = EncodeRobotMessage(message) else { return }

        if wifiDevice.session.connectedPeers.count > 0 {
            wifiDevice.sendData(jsonData, largeData: false)
        }
    }

    func processIncomingData(_ data: Data) {
        if LoadAndSetMap(data) { return }

        guard let message = ParseRobotMessageData(data) else { return }

        if let driveMessage = message as? DriveMotorMessage {
            robot.drive(withLeftMotorPower: driveMessage.leftMotorPower, rightMotorPower: driveMessage.rightMotorPower)
        } else if let locationMessage = message as? UpdateLocationMessage {
            updatePeerNode(locationMessage)
        } else if let addWaypoint = message as? WaypointAddMessage {
            addDrivingPoint(RobotMarker(flagNode: nil, flagId: addWaypoint.markerId, position: addWaypoint.location))
        } else if let clearWaypoint = message as? WaypointAchievedMessage {
            showCompletedMarker(clearWaypoint)
        } else if let statusMessage = message as? StatusMessage {
            switch statusMessage.statusMessage {
            case .emergencyStop:
                killRobot()
            case .missioncompleted:
                missioncompleted()
            case .resetMission:
                break
            }
        }
    }

    func missioncompleted() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = AudioPlayer.shared.play(.mission_complete)
        }
    }

    // Periodically send our location to other connected devices
    func startPeerTimer() {
        _ = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in

            guard let cam = self.sceneView.pointOfView else { return }

            let message = UpdateLocationMessage(location: cam.worldPosition,
                                                transform: cam.worldTransform,
                                                robotConnected: self.robot != nil,
                                                currentMapId: self.currentMapId,
                                                hasLocalized: self.hasFoundMapOnce,
                                                path: self.path) // TODO: add map here!

            self.sendMessage(message)
        }
    }

    func sendMap() {
        sceneView.session.getCurrentWorldMap { worldMap, error in
            guard let map = worldMap
            else { self.showAlert(title: "Can't get current world map", message: error!.localizedDescription); return }

            // Add a snapshot image indicating where the map was captured.
            guard let snapshotAnchor = SnapshotAnchor(capturing: self.sceneView)
            else { fatalError("Can't take snapshot") }

            let volxelMapAnchor = VoxelMapAnchor(map: self.voxelMap.getMapData())

            map.anchors.append(snapshotAnchor)
            map.anchors.append(volxelMapAnchor)

            let data = EncodeMapMessage(map)
            self.wifiDevice.sendData(data, largeData: false)
            self.areClientsSynced = true
            _ = AudioPlayer.shared.play(.uploading)
        }
    }

    func sendCompletedMarker(_ marker: RobotMarker) {
        let message = WaypointAchievedMessage(markerId: marker.flagId)
        sendMessage(message)
    }

    var lastStatusMessage: UpdateLocationMessage?
    var lastStatusDate: Date?

    var areClientsSynced = false

    // updates the robot projected path
    func updatePath(_ path: [SCNVector3]?) {
        if path == self.path { return }
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == "path" {
                node.removeFromParentNode()
            }
        }
        let box = SCNBox(width: CGFloat(0.05), height: CGFloat(0.05), length: CGFloat(0.05), chamferRadius: 0.1)
        box.firstMaterial?.diffuse.contents = UIColor.red
        let node = SCNNode(geometry: box)
        node.name = "path"

        path?.forEach { p in
            let pathNode = node.clone()
            pathNode.position = p
            self.scene.rootNode.addChildNode(pathNode)
        }
    }

    // Update the node position and add dot trail as the robot moves
    func updatePeerNode(_ result: UpdateLocationMessage) {
        lastStatusDate = Date()
        lastStatusMessage = result

        // Only update position if both devices are localized on the same map
        if areClientsSynced {
            if peerNode == nil {
                let ball = SCNPyramid(width: 0.06, height: 0.1, length: 0.06)
                ball.firstMaterial?.diffuse.contents = UIColor.magenta
                peerNode = SCNNode(geometry: ball)
                peerNode.eulerAngles.x = Float.pi
                scene.rootNode.addChildNode(peerNode)
            }

            let posPN = SCNVector3(result.location.x,
                                   result.location.y,
                                   result.location.z)

            peerNode.transform = result.transform
            addTrackingBall(posPN)
            updatePath(result.path)
        }

        DispatchQueue.main.async {
            if result.robotConnected {
                self.botConnectionState = .wifi
                self.robotStatusLabel.text = "Robot Wifi"
            } else {
                if self.robot == nil {
                    self.botConnectionState = .disconnected
                    self.robotStatusLabel.text = "Robot Off"
                }
            }
        }
    }

    private var lastPos: SCNVector3 = SCNVector3Zero
    private var balls: [SCNNode] = []
    private var ballIdx: Int = 0

    // Add dot trail with max dots
    func addTrackingBall(_ pos: SCNVector3) {
        if (pos - lastPos).length() < 0.012 { return }
        lastPos = pos

        let ball = SCNSphere(radius: 0.007)
        ball.firstMaterial?.diffuse.contents = (ballIdx % 2 == 0) ? UIColor.white : UIColor.red
        ball.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: ball)
        n.position = pos

        ballIdx += 1

        scene.rootNode.addChildNode(n)
        balls.append(n)

        let maxSize: Int = 150

        if balls.count > maxSize {
            let idx = balls.count - maxSize

            let b2 = balls[..<idx]

            for b in b2 {
                b.removeFromParentNode()
            }

            balls = Array(balls[idx...])
        }
    }

    // MARK: - Path

    var wayePointMarker: [RobotMarker] = []

    var isDriving: Bool = false

    var drivingDestination: SCNVector3 = SCNVector3Zero
    var driveQueue = DispatchQueue(label: "com.laan.driveQueue")

    func addDrivingPoint(_ marker: RobotMarker) {
        showStatus("Waypoint: " + String(marker.flagId))
        driveQueue.async {
            self.wayePointMarker.append(marker)

            if self.isDriving == false {
                self.driveCurrentPath_V2()
            }
        }
    }

    // MARK: - Load Map on robot

    func LoadAndSetMap(_ data: Data) -> Bool {
        do {
            if let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                // Run the session with the received world map.
                let configuration = ARWorldTrackingConfiguration()
                configuration.planeDetection = .horizontal
                configuration.initialWorldMap = worldMap
                guard let mapData = worldMap.anchors.filter({ $0.name == "VoxelMap" }).first
                else { fatalError("no volex map") }
                guard let voxlemap = (mapData as? VoxelMapAnchor) else {
                    fatalError("no volex map")
                }
                voxelMap.lodeMapFromData(voxlemap.map)
                augmentedRealitySession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                areClientsSynced = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                _ = AudioPlayer.shared.play(.data_transfer_complete)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Driving logic

    var leftPowerTween: Float = 0
    var rightPowerTween: Float = 0

    func driveCurrentPath_V2() {
        if isDriving { return }

        if !robot.isConnected { return }

        guard let cam = self.sceneView.pointOfView else { return }

        isDriving = true

        DispatchQueue.global().async {
            var end = false
            var currentWayPoint: RobotMarker!
            var currentPoint: SCNVector3!
            while !end {
                switch self.currentDriveState {
                case .getWaypoints:
                    // get point if exists
                    currentWayPoint = nil

                    self.driveQueue.sync {
                        if self.wayePointMarker.count > 0 {
                            currentWayPoint = self.wayePointMarker.remove(at: 0)
                            self.currentDriveState = .calculatePath
                        }
                    }
                    // out of points
                    if currentWayPoint == nil {
                        self.currentDriveState = .reachTarget
                    }
                    print("currentDriveState getWaypoints")
                case .calculatePath:
                    print("currentDriveState calculatePath")
                    let transform = cam.transform
                    let botPos = SCNVector3(transform.m41, transform.m42, transform.m43)
                    guard let marker = currentWayPoint?.position else { break }
                    self.voxelMap.getPath(start: botPos, end: marker)
                    self.currentDriveState = .waiting
                case .waiting:
                    print("currentDriveState waiting")
                    Thread.sleep(forTimeInterval: 1.0 / 15.0)

                case .getPoint:
                    print("currentDriveState getPoint")
                    // get point if exists
                    currentPoint = nil

                    self.driveQueue.sync {
                        if self.path.count > 0 {
                            currentPoint = self.path.remove(at: 0)
                            self.currentDriveState = .driveToTarget
                        }
                    }
                    // out of points
                    if currentPoint == nil {
                        self.currentDriveState = .getWaypoints
                    }

                case .driveToTarget:
                    print("currentDriveState driveToTarget")
                    let camPos = cam.worldPosition
                    let destPos = currentPoint.withY(y: cam.worldPosition.y)
                    let destMarkerPos = currentWayPoint.position.withY(y: cam.worldPosition.y)
                    let destDir = destPos - camPos
                    // phone faces opposite direction from bot forward
                    // so phone camera forward is -Z .. bot forward is Z
                    let botDir = cam.worldTransform.zAxis.withY(y: 0) * -1
                    let angleDiff = botDir.angle(between: destDir) * 180.0 / Float.pi

                    let minDistToWayPoint: Float = 0.15

                    // Is the point too close to robot to bother?
                    let distMarker = (camPos - destMarkerPos).length()
                    if distMarker < minDistToWayPoint {
                        self.sendCompletedMarker(currentWayPoint)
                        _ = AudioPlayer.shared.play(.target_range)
                        self.currentDriveState = .getWaypoints
                        break
                    }

                    // Is the point too close to robot to bother?
                    let dist = (camPos - destPos).length()
                    if dist < minDistToWayPoint {
                        self.currentDriveState = .getPoint
                        break
                    }

                    let turnRight = botDir.cross(vector: destDir).y < 0

                    var leftPower: Float = 0
                    var rightPower: Float = 0

                    let speed: Float = 0.6 + 0.2 * min(dist, 2.0)
                    let maxAngle: Float = 50.0

                    if angleDiff > maxAngle {
                        let turnPower: Float = 0.62

                        // just do turn around
                        leftPower = turnRight ? turnPower : -turnPower
                        rightPower = turnRight ? -turnPower : turnPower

                    } else {
                        let frac: Float = 0.1
                        // at center:  1 --> 0
                        let turnFactor = (1.0 - pow(angleDiff / maxAngle, 0.4))
                        let turnPower = frac + (speed - frac) * turnFactor

                        if turnRight {
                            leftPower = speed
                            rightPower = turnPower

                        } else {
                            rightPower = speed
                            leftPower = turnPower
                        }
                    }

                    self.leftPowerTween = self.leftPowerTween - (self.leftPowerTween - leftPower) * 0.2
                    self.rightPowerTween = self.rightPowerTween - (self.rightPowerTween - rightPower) * 0.2

                    self.robot.drive(withLeftMotorPower: self.leftPowerTween, rightMotorPower: self.rightPowerTween)

                    Thread.sleep(forTimeInterval: 1.0 / 15.0)

                case .reachTarget:
                    print("currentDriveState reachTarget")
                    self.currentDriveState = .getWaypoints
                    self.status("Finished Path")
                    _ = AudioPlayer.shared.play(.all_phases_complete)
                    self.sendMessage(StatusMessage(statusMessage: .missioncompleted))
                    self.robot.stopDriving()
                    self.isDriving = false
                    end = true
                }
            }
        }
    }

    func driveCurrentPath() {
        if isDriving { return }

        if !robot.isConnected { return }

        guard let cam = self.sceneView.pointOfView else { return }

        isDriving = true

        DispatchQueue.global().async {
            var currentWayPoint: RobotMarker!
            while true {
                currentWayPoint = nil

                self.driveQueue.sync {
                    if self.wayePointMarker.count > 0 {
                        currentWayPoint = self.wayePointMarker.remove(at: 0)
                    }
                }

                // out of points
                if currentWayPoint == nil {
                    break
                }
                var currentPoint: RobotMarker!
                while true {
                    // get point if exists
                    currentPoint = nil

                    self.driveQueue.sync {
                        if self.wayePointMarker.count > 0 {
                            currentPoint = self.wayePointMarker.remove(at: 0)
                        }
                    }

                    // out of points
                    if currentPoint == nil {
                        break
                    }

                    // TODO: Better path planning
                    // RM_DRIVE_RADIUS_TURN_IN_PLACE = 0
                    // let r1 = RM_DRIVE_RADIUS_TURN_IN_PLACE
                    // self.robot.drive(withRadius: 0, speed: 1)

                    // Run drive + adjust loop
                    while true {
                        let camPos = cam.worldPosition
                        let destPos = currentPoint.position.withY(y: cam.worldPosition.y)
                        let destDir = destPos - camPos
                        // phone faces opposite direction from bot forward
                        // so phone camera forward is -Z .. bot forward is Z
                        let botDir = cam.worldTransform.zAxis.withY(y: 0) * -1
                        let angleDiff = botDir.angle(between: destDir) * 180.0 / Float.pi

                        let minDistToWayPoint: Float = 0.15

                        // Is the point too close to robot to bother?
                        let dist = (camPos - destPos).length()
                        if dist < minDistToWayPoint {
                            self.sendCompletedMarker(currentPoint)
                            _ = AudioPlayer.shared.play(.target_range)
                            break
                        }

                        let turnRight = botDir.cross(vector: destDir).y < 0

                        var leftPower: Float = 0
                        var rightPower: Float = 0

                        let speed: Float = 0.6 + 0.2 * min(dist, 2.0)
                        let maxAngle: Float = 50.0

                        if angleDiff > maxAngle {
                            let turnPower: Float = 0.62

                            // just do turn around
                            leftPower = turnRight ? turnPower : -turnPower
                            rightPower = turnRight ? -turnPower : turnPower

                        } else {
                            let frac: Float = 0.1
                            // at center:  1 --> 0
                            let turnFactor = (1.0 - pow(angleDiff / maxAngle, 0.4))
                            let turnPower = frac + (speed - frac) * turnFactor

                            if turnRight {
                                leftPower = speed
                                rightPower = turnPower

                            } else {
                                rightPower = speed
                                leftPower = turnPower
                            }
                        }

                        self.leftPowerTween = self.leftPowerTween - (self.leftPowerTween - leftPower) * 0.2
                        self.rightPowerTween = self.rightPowerTween - (self.rightPowerTween - rightPower) * 0.2

                        self.robot.drive(withLeftMotorPower: self.leftPowerTween, rightMotorPower: self.rightPowerTween)

                        Thread.sleep(forTimeInterval: 1.0 / 15.0)
                    }
                }
            }

            // self.status("Finished Path")
            _ = AudioPlayer.shared.play(.all_phases_complete)
            self.sendMessage(StatusMessage(statusMessage: .missioncompleted))
            self.robot.stopDriving()
            self.isDriving = false
        }
    }

    func status(_ s: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = s
        }
    }

    func killRobot() {
        if robot == nil { return } // Kill only the robot.
        var duration = 1.0
        DispatchQueue.main.async {
            duration = AudioPlayer.shared.play(.c_system_shut_down)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1) { fatalError() }
    }

    // MARK: -

    struct RobotMarker {
        var flagNode: SCNNode!
        var flagId: Int
        var position: SCNVector3
    }

    var pendingCommands: [RobotMarker] = []
    var visibleFlags: [RobotMarker] = []

    func showCompletedMarker(_ message: WaypointAchievedMessage) {
        for marker in visibleFlags {
            if marker.flagId == message.markerId {
                // Turn pin green
                if let cyl = marker.flagNode.childNode(withName: "sphere", recursively: true) {
                    cyl.geometry?.firstMaterial?.diffuse.contents = UIColor.green
                }

                return
            }
        }
    }

    var prevPos: SCNVector3!

    // Adds a 3d pin and draws a line if there was a previous pin
    func addDriveToMarker(_ p: SCNVector3) {
        let pin = newPinMarker()!
        pin.worldPosition = p
        pin.scale = .one * 3.25
        scene.rootNode.addChildNode(pin)

        if let prev = prevPos {
            let line = SKLine(radius: 0.005, color: UIColor.white.withAlphaComponent(0.9), start: prev, end: p)
            line.capsule.firstMaterial?.lightingModel = .constant

            let surf = """
            
            #pragma transparent
            #pragma body
            float ss = sin( 15.0 * u_time + _surface.diffuseTexcoord.y * 35.0 );
            float yy = 0.1 + 0.45 + 0.45 * ss;
            _surface.diffuse.a = yy;
            
            if ( ss > 0.9 ) {
                _surface.diffuse.rgb = vec3(0.25,0.85,1.0);
            } else if ( ss < 0.0 ) {
                _surface.diffuse.rgb = vec3(0.0,0.3,0.9);
            } else {
                _surface.diffuse.rgb = vec3(0.0,0.6,1.0);
            }
            """

            line.capsule.firstMaterial?.shaderModifiers = [SCNShaderModifierEntryPoint.surface: surf]

            scene.rootNode.addChildNode(line)
        }

        prevPos = p

        let flagId = Int(arc4random() % 100_000)
        let marker = RobotMarker(flagNode: pin, flagId: flagId, position: p)

        visibleFlags.append(marker)
        pendingCommands.append(marker)
    }

    @objc func sendAllPendingMarkers(_ sender: Any?) {
        if let b = sender as? UIButton {
            UIView.animate(withDuration: 0.2, animations: {
                b.backgroundColor = UIColor.white
                b.setTitleColor(UIColor.appleBlueColor, for: .normal)

            }) { _ in

                UIView.animate(withDuration: 0.2) {
                    b.setTitleColor(UIColor.white, for: .normal)
                    b.backgroundColor = UIColor.appleBlueColor
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            _ = AudioPlayer.shared.play(.uploading)
        }

        DispatchQueue.global().async {
            self.showStatus("Sending " + String(self.pendingCommands.count) + " cmds")

            for marker in self.pendingCommands {
                self.sendMarkerCommand(marker)
                Thread.sleep(forTimeInterval: 0.15)
            }
            self.pendingCommands.removeAll()
        }
    }

    func sendDriveToPos(_: SCNVector3) {
        assert(false)
    }

    func sendMarkerCommand(_ marker: RobotMarker) {
        sendMessage(WaypointAddMessage(markerId: marker.flagId, location: marker.position))
    }

    var pinNode: SCNNode?

    func newPinMarker(color: UIColor = UIColor.magenta,
                      addLights _: Bool = true,
                      constantLighting: Bool = false) -> SCNNode? {
        guard let pinRoot = SCNScene(named: "pin.scn")?.rootNode else { return nil }

        guard let pin = pinRoot.childNode(withName: "pin", recursively: true) else { return nil }

        if let cyl = pin.childNode(withName: "cylinder", recursively: true) {
            cyl.renderingOrder = 5601
            if constantLighting {
                cyl.geometry?.firstMaterial?.lightingModel = .constant
            }
        }

        if let cyl = pin.childNode(withName: "cone", recursively: true) {
            cyl.renderingOrder = 5600
            if constantLighting {
                cyl.geometry?.firstMaterial?.lightingModel = .constant
            }
        }

        if let cyl = pin.childNode(withName: "sphere", recursively: true) {
            cyl.geometry?.firstMaterial?.diffuse.contents = color
            cyl.renderingOrder = 5602
            if constantLighting {
                cyl.geometry?.firstMaterial?.lightingModel = .constant
            }
        }

        return pin
    }

    // MARK: - Driving View

    func showDrivingView() {
        if driveView == nil {
            driveView = TouchDriveView(size: 150)
            driveView.delegate = self
        }

        view.addSubview(driveView.powerView)
        view.addSubview(driveView.steeringView)
    }

    func hideDrivingView() {
        driveView?.powerView.removeFromSuperview()
        driveView?.steeringView.removeFromSuperview()
    }

    private var lastDriveMessage = Date()

    func valueChanged(steering: Float, power: Float) {
        if botConnectionState == .wifi {
            // && lastDriveMessage.millisecondsAgo > 100.0
            // lastDriveMessage = Date()

            var leftPower: Float = 0.0 // steering * power
            var rightPower: Float = 0.0 // steering * power * -1.0

            if steering >= 0 {
                leftPower = 1.0
                rightPower = 1.0 - 2.0 * steering

            } else {
                rightPower = 1.0
                leftPower = 1.0 + 2.0 * steering
            }

            rightPower *= power
            leftPower *= power

            sendMessage(DriveMotorMessage(leftMotorPower: leftPower, rightMotorPower: rightPower))
        }
    }
}

extension ViewController: SlideButtonDelegate {
    func buttonStatus(status _: String, sender _: MMSlidingButton) {
        sendMessage(StatusMessage(statusMessage: .emergencyStop))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            _ = AudioPlayer.shared.play(.program_terminated)
        }
    }
}

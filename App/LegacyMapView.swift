import SwiftUI
import MapKit

/// Sustituto de `MapCameraPosition` (solo iOS 17+).
/// Cada vez que se crea con `.region(...)` recibe un id nuevo, y el mapa
/// solo se recoloca cuando ese id cambia (asi no peleamos con los gestos del usuario).
struct CameraPos: Equatable {
    let id: UUID
    var region: MKCoordinateRegion

    init(region: MKCoordinateRegion) {
        self.id = UUID()
        self.region = region
    }

    static func region(_ region: MKCoordinateRegion) -> CameraPos {
        CameraPos(region: region)
    }

    static func == (lhs: CameraPos, rhs: CameraPos) -> Bool {
        lhs.id == rhs.id
    }
}

final class TargetAnnotation: MKPointAnnotation {}

/// Mapa basado en MKMapView (iOS 13+) con marcador, ubicacion del usuario y toque para elegir coordenada.
struct LegacyMapView: UIViewRepresentable {
    var camera: CameraPos
    var markerCoordinate: CLLocationCoordinate2D?
    var markerTitle: String = "Target Location"
    var onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.showsUserLocation = !LocationServicesToggle.isCycling
        context.coordinator.map = map
        map.pointOfInterestFilter = .includingAll
        map.setRegion(camera.region, animated: false)
        context.coordinator.lastCameraID = camera.id

        let doubleTap = UITapGestureRecognizer()
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        map.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.require(toFail: doubleTap)
        map.addGestureRecognizer(tap)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onTap = onTap

        if context.coordinator.lastCameraID != camera.id {
            context.coordinator.lastCameraID = camera.id
            map.setRegion(camera.region, animated: true)
        }

        let existing = map.annotations.compactMap { $0 as? TargetAnnotation }
        if let c = markerCoordinate {
            if let a = existing.first {
                if a.coordinate.latitude != c.latitude || a.coordinate.longitude != c.longitude {
                    a.coordinate = c
                }
            } else {
                let a = TargetAnnotation()
                a.coordinate = c
                a.title = markerTitle
                map.addAnnotation(a)
            }
        } else if !existing.isEmpty {
            map.removeAnnotations(existing)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CLLocationCoordinate2D) -> Void
        var lastCameraID: UUID?
        weak var map: MKMapView?
        private var observers: [NSObjectProtocol] = []

        init(onTap: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTap = onTap
            super.init()
            // Pause user-location tracking while Location Services is being restarted,
            // otherwise iOS shows the "Turn On Location Services…" alert.
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .locationCycleWillStart, object: nil, queue: .main) { [weak self] _ in
                self?.map?.showsUserLocation = false
            })
            observers.append(nc.addObserver(forName: .locationCycleDidEnd, object: nil, queue: .main) { [weak self] _ in
                self?.map?.showsUserLocation = true
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)

            // Ignorar toques sobre un marcador existente
            var view: UIView? = map.hitTest(point, with: nil)
            while let v = view {
                if v is MKAnnotationView { return }
                view = v.superview
            }

            onTap(map.convert(point, toCoordinateFrom: map))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

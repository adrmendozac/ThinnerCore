/// Core logic for the Universal Binary Thinner, used by the `thinnercore`
/// CLI and kept separate from it so it can be tested on its own. Every
/// destructive operation lives behind one audited code path in this module.
public enum ThinnerCore {
    public static let version = "0.1.0"
}

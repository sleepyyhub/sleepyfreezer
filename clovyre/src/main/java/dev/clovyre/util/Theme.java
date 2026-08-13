package dev.clovyre.util;

/** Palette pulled from the Clovyre mark. ARGB ints, because that is what DrawContext wants. */
public final class Theme {

    public static final int ACCENT      = 0xFF3CD070; // emerald — primary
    public static final int HIGHLIGHT   = 0xFFA3E635; // lime — enabled state
    public static final int PANEL       = 0xE60D1117; // GUI background, slightly translucent
    public static final int PANEL_LIGHT = 0xFF161B22;
    public static final int TEXT        = 0xFFE6EDF3;
    public static final int TEXT_DIM    = 0xFF8B949E;

    private Theme() {}

    /**
     * Blends ACCENT into HIGHLIGHT. Used for the arraylist so the module list carries the
     * same top-left-to-bottom-right gradient as the logo.
     *
     * @param t 0.0 = accent, 1.0 = highlight
     */
    public static int gradient(float t) {
        t = Math.max(0f, Math.min(1f, t));
        int ar = (ACCENT >> 16) & 0xFF, ag = (ACCENT >> 8) & 0xFF, ab = ACCENT & 0xFF;
        int br = (HIGHLIGHT >> 16) & 0xFF, bg = (HIGHLIGHT >> 8) & 0xFF, bb = HIGHLIGHT & 0xFF;
        int r = (int) (ar + (br - ar) * t);
        int g = (int) (ag + (bg - ag) * t);
        int b = (int) (ab + (bb - ab) * t);
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }
}

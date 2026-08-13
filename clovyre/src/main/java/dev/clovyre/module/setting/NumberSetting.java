package dev.clovyre.module.setting;

public class NumberSetting extends Setting<Double> {

    private final double min;
    private final double max;
    private final double step;

    public NumberSetting(String name, double defaultValue, double min, double max, double step) {
        super(name, defaultValue);
        this.min = min;
        this.max = max;
        this.step = step;
    }

    @Override
    public void set(Double value) {
        double clamped = Math.max(min, Math.min(max, value));
        // Snap to the nearest step so dragging a slider yields clean values, not 0.4700000001.
        super.set(Math.round(clamped / step) * step);
    }

    /** Sets from a 0..1 slider position. */
    public void setFromFraction(double fraction) {
        set(min + (max - min) * Math.max(0, Math.min(1, fraction)));
    }

    /** Current value as a 0..1 slider position. */
    public double asFraction() {
        return (get() - min) / (max - min);
    }

    public float getFloat() {
        return get().floatValue();
    }

    public int getInt() {
        return (int) Math.round(get());
    }

    @Override
    public String display() {
        return step >= 1 ? String.valueOf(getInt()) : String.format("%.2f", get());
    }
}

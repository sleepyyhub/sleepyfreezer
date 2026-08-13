package dev.clovyre.module.setting;

public class BoolSetting extends Setting<Boolean> {

    public BoolSetting(String name, boolean defaultValue) {
        super(name, defaultValue);
    }

    public void toggle() {
        set(!get());
    }

    @Override
    public String display() {
        return get() ? "ON" : "OFF";
    }
}

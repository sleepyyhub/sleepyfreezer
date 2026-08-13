package dev.clovyre.module.setting;

import java.util.Arrays;
import java.util.List;

/** A cycling list of named options — "Mode: Vanilla / Motion / Packet". */
public class ModeSetting extends Setting<String> {

    private final List<String> modes;

    public ModeSetting(String name, String defaultValue, String... modes) {
        super(name, defaultValue);
        this.modes = Arrays.asList(modes);
    }

    public void cycle() {
        int next = (modes.indexOf(get()) + 1) % modes.size();
        set(modes.get(next));
    }

    public boolean is(String mode) {
        return get().equalsIgnoreCase(mode);
    }

    public List<String> getModes() {
        return modes;
    }

    @Override
    public String display() {
        return get();
    }
}

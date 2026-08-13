package dev.clovyre.module.setting;

/** Base for anything a module exposes in the ClickGUI. */
public abstract class Setting<T> {

    private final String name;
    protected T value;

    protected Setting(String name, T defaultValue) {
        this.name = name;
        this.value = defaultValue;
    }

    public String getName() {
        return name;
    }

    public T get() {
        return value;
    }

    public void set(T value) {
        this.value = value;
    }

    /** Rendered on the right-hand side of the setting row. */
    public abstract String display();
}

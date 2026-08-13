package dev.clovyre.module;

import dev.clovyre.Clovyre;
import dev.clovyre.module.setting.Setting;
import net.minecraft.client.MinecraftClient;
import org.lwjgl.glfw.GLFW;

import java.util.ArrayList;
import java.util.List;

/**
 * Base class for everything the client does.
 *
 * Lifecycle: onEnable/onDisable fire on toggle, onTick fires once per client tick (20/s)
 * while enabled, onRender fires once per frame while enabled. Subclasses override what
 * they need and ignore the rest.
 */
public abstract class Module {

    protected static final MinecraftClient mc = MinecraftClient.getInstance();

    private final String name;
    private final String description;
    private final Category category;
    private final List<Setting<?>> settings = new ArrayList<>();

    private int key = GLFW.GLFW_KEY_UNKNOWN;
    private boolean enabled;
    /** Hidden modules stay out of the HUD arraylist — ClickGui shouldn't list itself as "active". */
    private boolean visible = true;

    protected Module(String name, String description, Category category) {
        this.name = name;
        this.description = description;
        this.category = category;
    }

    // --- overridable hooks -------------------------------------------------

    public void onEnable() {}

    public void onDisable() {}

    public void onTick() {}

    public void onRender() {}

    // --- toggling ----------------------------------------------------------

    public void toggle() {
        setEnabled(!enabled);
    }

    public void setEnabled(boolean state) {
        if (this.enabled == state) return;
        this.enabled = state;

        // Guard the hooks: a module toggled from the main menu has no world to touch.
        try {
            if (state) onEnable();
            else onDisable();
        } catch (Exception e) {
            Clovyre.LOG.error("{} threw while toggling", name, e);
            this.enabled = false;
        }
    }

    public boolean isEnabled() {
        return enabled;
    }

    // --- settings ----------------------------------------------------------

    protected <T extends Setting<?>> T register(T setting) {
        settings.add(setting);
        return setting;
    }

    public List<Setting<?>> getSettings() {
        return settings;
    }

    // --- accessors ---------------------------------------------------------

    public String getName() {
        return name;
    }

    public String getDescription() {
        return description;
    }

    public Category getCategory() {
        return category;
    }

    public int getKey() {
        return key;
    }

    public void setKey(int key) {
        this.key = key;
    }

    public boolean isVisible() {
        return visible;
    }

    protected void setVisible(boolean visible) {
        this.visible = visible;
    }

    /** What the HUD arraylist shows — override to append state, e.g. "Flight [Creative]". */
    public String getHudText() {
        return name;
    }
}

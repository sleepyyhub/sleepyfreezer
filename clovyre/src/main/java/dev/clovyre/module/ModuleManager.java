package dev.clovyre.module;

import dev.clovyre.Clovyre;
import dev.clovyre.module.modules.ClickGuiModule;
import dev.clovyre.module.modules.Flight;
import dev.clovyre.module.modules.Fullbright;
import dev.clovyre.module.modules.Sprint;
import org.lwjgl.glfw.GLFW;

import java.util.ArrayList;
import java.util.List;

/**
 * Owns every module instance and fans the mixin-sourced events out to them.
 * Register new modules in the constructor — that is the only wiring step.
 */
public class ModuleManager {

    private final List<Module> modules = new ArrayList<>();

    public ModuleManager() {
        add(new ClickGuiModule(), GLFW.GLFW_KEY_RIGHT_SHIFT);
        add(new Fullbright(), GLFW.GLFW_KEY_G);
        add(new Sprint(), GLFW.GLFW_KEY_V);
        add(new Flight(), GLFW.GLFW_KEY_F);
    }

    private void add(Module module, int defaultKey) {
        module.setKey(defaultKey);
        modules.add(module);
    }

    // --- event fan-out (called from mixins) --------------------------------

    public void onTick() {
        for (Module module : modules) {
            if (!module.isEnabled()) continue;
            try {
                module.onTick();
            } catch (Exception e) {
                Clovyre.LOG.error("{} threw in onTick, disabling", module.getName(), e);
                module.setEnabled(false);
            }
        }
    }

    public void onRender() {
        for (Module module : modules) {
            if (!module.isEnabled()) continue;
            try {
                module.onRender();
            } catch (Exception e) {
                Clovyre.LOG.error("{} threw in onRender, disabling", module.getName(), e);
                module.setEnabled(false);
            }
        }
    }

    public void onKeyPressed(int key) {
        if (key == GLFW.GLFW_KEY_UNKNOWN) return;
        for (Module module : modules) {
            if (module.getKey() == key) module.toggle();
        }
    }

    // --- lookups -----------------------------------------------------------

    public List<Module> getModules() {
        return modules;
    }

    public List<Module> getByCategory(Category category) {
        return modules.stream().filter(m -> m.getCategory() == category).toList();
    }

    /** Enabled and HUD-visible, longest name first — the classic arraylist ordering. */
    public List<Module> getActiveForHud() {
        return modules.stream()
                .filter(Module::isEnabled)
                .filter(Module::isVisible)
                .sorted((a, b) -> Integer.compare(
                        Clovyre.mc().textRenderer.getWidth(b.getHudText()),
                        Clovyre.mc().textRenderer.getWidth(a.getHudText())))
                .toList();
    }

    public Module getByName(String name) {
        return modules.stream()
                .filter(m -> m.getName().equalsIgnoreCase(name))
                .findFirst()
                .orElse(null);
    }
}

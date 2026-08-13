package dev.clovyre;

import dev.clovyre.module.ModuleManager;
import net.fabricmc.api.ClientModInitializer;
import net.minecraft.client.MinecraftClient;
import net.minecraft.text.Text;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Entry point. Fabric calls onInitializeClient() once, before the game window exists,
 * so nothing here may touch MinecraftClient state directly — only build managers.
 */
public class Clovyre implements ClientModInitializer {

    public static final String NAME = "Clovyre";
    public static final String VERSION = "0.1.0";
    public static final Logger LOG = LoggerFactory.getLogger(NAME);

    private static ModuleManager moduleManager;

    @Override
    public void onInitializeClient() {
        moduleManager = new ModuleManager();
        LOG.info("{} v{} loaded — {} modules registered.", NAME, VERSION, moduleManager.getModules().size());
    }

    public static ModuleManager modules() {
        return moduleManager;
    }

    public static MinecraftClient mc() {
        return MinecraftClient.getInstance();
    }

    /** Client-side chat print, prefixed. Never reaches the server. */
    public static void chat(String message) {
        MinecraftClient mc = mc();
        if (mc.player == null) return;
        mc.player.sendMessage(Text.literal("§a[" + NAME + "] §f" + message), false);
    }
}

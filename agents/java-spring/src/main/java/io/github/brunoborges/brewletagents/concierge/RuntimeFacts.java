package io.github.brunoborges.brewletagents.concierge;

import java.io.IOException;
import java.io.InputStream;
import java.net.URISyntaxException;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;

import com.microsoft.copilot.CopilotClient;
import com.microsoft.copilot.tool.CopilotTool;
import com.microsoft.copilot.tool.CopilotToolParam;
import org.springframework.boot.SpringBootVersion;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;

/**
 * The facts the Runtime Concierge reports, both over GET /runtime and to the model through the runtime_facts tool.
 * Everything is read from the live process, so the answer shows what Brewlet actually launched.
 */
@Service
public class RuntimeFacts {

    private static final String SDK = "com.microsoft/copilot-sdk";
    private static final String INTEGRATION = "com.microsoft/copilot-spring-boot-autoconfigure";

    private final SidecarProbe sidecar;
    private final Environment env;

    public RuntimeFacts(SidecarProbe sidecar, Environment env) {
        this.sidecar = sidecar;
        this.env = env;
    }

    public Map<String, Object> describe() {
        Map<String, Object> facts = new LinkedHashMap<>();
        facts.put("agent", agent());
        facts.put("language", language());
        facts.put("copilot", copilot());
        facts.put("deployment", deployment());
        return facts;
    }

    @CopilotTool(name = "runtime_facts", value = "Verified facts about the environment this agent runs in: the Java runtime"
            + " (version, home directory), the application artifact (framework, code location), the Copilot SDK and"
            + " integration versions, the Copilot CLI sidecar (version, authentication) and the Kubernetes/Brewlet"
            + " deployment (runtime image id, pod). Call it before answering any question about these.")
    public String runtimeFacts(
            @CopilotToolParam("Which part to return: all, language, agent, copilot or deployment") String topic) {
        Map<String, Object> facts = describe();
        String wanted = topic == null ? "all" : topic.strip().toLowerCase();
        if (!wanted.equals("all") && facts.containsKey(wanted)) {
            facts = Map.of(wanted, facts.get(wanted));
        }
        StringBuilder text = new StringBuilder();
        flatten("", facts, text);
        return text.toString();
    }

    private Map<String, Object> agent() {
        Map<String, Object> agent = new LinkedHashMap<>();
        agent.put("name", env.getProperty("AGENT_NAME", "java-spring"));
        agent.put("framework", Map.of("name", "Spring Boot", "version", SpringBootVersion.getVersion()));
        agent.put("location", locationOf(ConciergeApplication.class));
        return agent;
    }

    private Map<String, Object> language() {
        Map<String, Object> language = new LinkedHashMap<>();
        language.put("name", "java");
        language.put("version", Runtime.version().toString());
        language.put("vendor", System.getProperty("java.vendor"));
        language.put("home", System.getProperty("java.home"));
        return language;
    }

    private Map<String, Object> copilot() {
        Map<String, Object> copilot = new LinkedHashMap<>();
        copilot.put("sdk", library(SDK, CopilotClient.class));
        copilot.put("integration", library(INTEGRATION,
                com.microsoft.copilot.integrations.springboot.autoconfigure.CopilotAutoConfiguration.class));
        copilot.put("cli", sidecar.describe());
        return copilot;
    }

    private Map<String, Object> deployment() {
        Map<String, Object> deployment = new LinkedHashMap<>();
        deployment.put("runtimeId", env.getProperty("AGENT_RUNTIME_ID", "unknown"));
        deployment.put("pod", env.getProperty("POD_NAME", env.getProperty("HOSTNAME", "unknown")));
        deployment.put("namespace", env.getProperty("POD_NAMESPACE", "unknown"));
        deployment.put("node", env.getProperty("NODE_NAME", "unknown"));
        return deployment;
    }

    private static Map<String, Object> library(String coordinates, Class<?> anchor) {
        Map<String, Object> library = new LinkedHashMap<>();
        library.put("name", coordinates.replace('/', ':'));
        library.put("version", mavenVersion(coordinates));
        library.put("location", locationOf(anchor));
        return library;
    }

    private static String mavenVersion(String coordinates) {
        String resource = "/META-INF/maven/" + coordinates + "/pom.properties";
        try (InputStream in = RuntimeFacts.class.getResourceAsStream(resource)) {
            if (in == null) {
                return "unknown";
            }
            Properties pom = new Properties();
            pom.load(in);
            return pom.getProperty("version", "unknown");
        } catch (IOException e) {
            return "unknown";
        }
    }

    private static String locationOf(Class<?> type) {
        try {
            return Path.of(type.getProtectionDomain().getCodeSource().getLocation().toURI()).toString();
        } catch (URISyntaxException | RuntimeException e) {
            return "unknown";
        }
    }

    private static void flatten(String prefix, Map<?, ?> values, StringBuilder out) {
        values.forEach((key, value) -> {
            String name = prefix.isEmpty() ? String.valueOf(key) : prefix + "." + key;
            if (value instanceof Map<?, ?> nested) {
                flatten(name, nested, out);
            } else {
                out.append(name).append(": ").append(value).append('\n');
            }
        });
    }
}

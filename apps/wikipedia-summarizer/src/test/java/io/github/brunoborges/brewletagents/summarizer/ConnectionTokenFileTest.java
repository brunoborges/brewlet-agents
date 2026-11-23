package io.github.brunoborges.brewletagents.summarizer;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/**
 * The Pod mounts one key of the Secret copilot-cli as /app/secrets/connection-token and sets
 * SPRING_CONFIG_IMPORT=configtree:/app/secrets/ (deployment.yaml). That file is how the token reaches the
 * starter's copilot.tcp-connection-token: it must not be an environment variable, because the jlib-inspector agent
 * of the java-25-jlib runtime reports the whole environment.
 */
@SpringBootTest(classes = ConnectionTokenFileTest.NoBeans.class, webEnvironment = SpringBootTest.WebEnvironment.NONE,
        properties = "spring.config.import=configtree:${test.secrets.dir}/")
class ConnectionTokenFileTest {

    @TempDir
    static Path secrets;

    @BeforeAll
    static void mountTheSecret() throws IOException {
        Files.writeString(secrets.resolve("connection-token"), "token-from-the-mounted-file");
        System.setProperty("test.secrets.dir", secrets.toString());
    }

    @AfterAll
    static void unmountTheSecret() {
        System.clearProperty("test.secrets.dir");
    }

    @Autowired
    Environment environment;

    @Test
    void readsTheConnectionTokenFromTheMountedFile() {
        assertThat(environment.getProperty("copilot.tcp-connection-token")).isEqualTo("token-from-the-mounted-file");
    }

    @Configuration
    static class NoBeans {
    }
}

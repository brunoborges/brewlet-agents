package io.github.brunoborges.brewletagents.summarizer;

import org.springframework.http.HttpStatus;

/** A failure that the API reports as {@code {"error": code, "message": message}} with the given HTTP status. */
final class ApiException extends RuntimeException {

    private final HttpStatus status;
    private final String code;

    ApiException(HttpStatus status, String code, String message) {
        this(status, code, message, null);
    }

    ApiException(HttpStatus status, String code, String message, Throwable cause) {
        super(message, cause);
        this.status = status;
        this.code = code;
    }

    HttpStatus status() {
        return status;
    }

    String code() {
        return code;
    }
}

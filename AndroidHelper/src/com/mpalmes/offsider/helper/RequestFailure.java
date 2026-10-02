package com.mpalmes.offsider.helper;

/** A failed request: the helper answers with an error envelope and keeps serving. */
final class RequestFailure extends Exception {
    private static final long serialVersionUID = 1L;

    final String code;
    final String detail;
    String className;
    String resourceId;

    RequestFailure(String code, String message, String detail) {
        super(message);
        this.code = code;
        this.detail = detail;
    }

    static RequestFailure badRequest(String message) {
        return new RequestFailure("bad-request", message, null);
    }

    static RequestFailure staleNode(String message) {
        return new RequestFailure("stale-node", message, null);
    }

    static RequestFailure unsupported(String message) {
        return new RequestFailure("action-unsupported", message, null);
    }

    /** Names the node the request acted on, for errors about the focused field. */
    RequestFailure node(CharSequence nodeClass, String nodeId) {
        this.className = nodeClass == null ? null : nodeClass.toString();
        this.resourceId = nodeId;
        return this;
    }
}

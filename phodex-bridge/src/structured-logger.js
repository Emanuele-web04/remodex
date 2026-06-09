// FILE: structured-logger.js
// Purpose: Structured logging with consistent JSON format for observability
// Layer: Logging utility
// Exports: createStructuredLogger

/**
 * Creates a structured logger with consistent JSON format
 * @param {string} component - Component name for log prefix
 * @returns {Object} Logger with info, warn, error methods
 */
function createStructuredLogger(component) {
  const prefix = component || "[remodex]";

  return {
    /**
     * Log info-level message with structured context
     * @param {string} message - Log message
     * @param {Object} context - Structured context (threadId, turnId, sessionId, etc.)
     */
    info(message, context = {}) {
      const logEntry = {
        level: "info",
        timestamp: new Date().toISOString(),
        component: prefix,
        message,
        ...context,
      };
      console.log(JSON.stringify(logEntry));
    },

    /**
     * Log warning message with structured context
     * @param {string} message - Warning message
     * @param {Object} context - Structured context
     */
    warn(message, context = {}) {
      const logEntry = {
        level: "warn",
        timestamp: new Date().toISOString(),
        component: prefix,
        message,
        ...context,
      };
      console.warn(JSON.stringify(logEntry));
    },

    /**
     * Log error message with structured context
     * @param {string} message - Error message
     * @param {Error|Object} error - Error object or additional context
     * @param {Object} context - Additional structured context
     */
    error(message, error = null, context = {}) {
      const logEntry = {
        level: "error",
        timestamp: new Date().toISOString(),
        component: prefix,
        message,
        ...context,
      };

      if (error) {
        if (error instanceof Error) {
          logEntry.error = {
            message: error.message,
            code: error.code,
            stack: error.stack,
          };
        } else {
          logEntry.error = error;
        }
      }

      console.error(JSON.stringify(logEntry));
    },

    /**
     * Log debug message with structured context (only in test/dev)
     * @param {string} message - Debug message
     * @param {Object} context - Structured context
     */
    debug(message, context = {}) {
      if (process.env.REMODEX_DEBUG === "1" || process.env.NODE_ENV === "test") {
        const logEntry = {
          level: "debug",
          timestamp: new Date().toISOString(),
          component: prefix,
          message,
          ...context,
        };
        console.log(JSON.stringify(logEntry));
      }
    },
  };
}

/**
 * Extract common context from provider/handler objects
 * @param {Object} params - Parameters object that may contain threadId, turnId, sessionId
 * @returns {Object} Extracted context
 */
function extractLogContext(params = {}) {
  if (!params || typeof params !== 'object') {
    return {};
  }
  
  const context = {};
  if (params.threadId || params.thread_id) {
    context.threadId = params.threadId || params.thread_id;
  }
  if (params.turnId || params.turn_id) {
    context.turnId = params.turnId || params.turn_id;
  }
  if (params.sessionId || params.session_id) {
    context.sessionId = params.sessionId || params.session_id;
  }
  if (params.method) {
    context.method = params.method;
  }
  return context;
}

module.exports = {
  createStructuredLogger,
  extractLogContext,
};
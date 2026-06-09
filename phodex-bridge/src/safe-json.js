// FILE: safe-json.js
// Purpose: Secure JSON parsing with prototype pollution protection
// Layer: Security utility
// Exports: safeParseJSON

/**
 * Safely parses JSON with prototype pollution protection.
 * Prevents prototype pollution attacks by sanitizing dangerous keys.
 * 
 * @param {string} input - JSON string to parse
 * @param {function} [reviver] - Optional custom reviver function
 * @returns {object|null} Parsed object or null if parsing fails
 */
function safeParseJSON(input, reviver) {
  if (typeof input !== "string") {
    return null;
  }

  const trimmed = input.trim();
  if (!trimmed) {
    return null;
  }

  try {
    const dangerousKeys = ["__proto__", "constructor", "prototype"];
    
    const safeReviver = (key, value) => {
      // Skip dangerous keys to prevent prototype pollution
      if (dangerousKeys.includes(key)) {
        return undefined;
      }
      
      // Apply custom reviver if provided
      if (reviver) {
        return reviver(key, value);
      }
      
      return value;
    };

    return JSON.parse(trimmed, safeReviver);
  } catch (error) {
    return null;
  }
}

/**
 * Creates a null-prototype object to prevent prototype pollution.
 * Use this when creating objects that will hold user-controlled data.
 * 
 * @returns {object} Object with null prototype
 */
function createNullObject() {
  return Object.create(null);
}

module.exports = {
  safeParseJSON,
  createNullObject,
};
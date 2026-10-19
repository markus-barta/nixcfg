// Deliberately bounded JSON Schema vocabulary used by this contract set.
// This is not a general JSON Schema implementation. No remote refs or coercion.
export function resolveRef(ref, root, files) {
  const [file, fragment = ''] = ref.split('#');
  const document = file ? files[file] : root;
  if (!document) throw new TypeError('Unknown schema file');
  const schema = fragment.split('/').slice(1).reduce((v, key) =>
    v?.[key.replace(/~1/g, '/').replace(/~0/g, '~')], document);
  if (!schema) throw new TypeError('Unknown schema fragment');
  return { schema, root: document };
}

export function validDate(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(`${value}T00:00:00.000Z`)) &&
    new Date(`${value}T00:00:00.000Z`).toISOString().slice(0, 10) === value;
}

export function validInstant(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
    Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
}

export function checkSchema(schema, value, files, errors = [], at = '$', root = schema) {
  if (errors.length >= 32) return errors;
  const fail = rule => { if (errors.length < 32) errors.push({ path: at, rule }); };
  if (schema.$ref) {
    const target = resolveRef(schema.$ref, root, files);
    checkSchema(target.schema, value, files, errors, at, target.root);
  }
  if (schema.anyOf && !schema.anyOf.some(s => checkSchema(s, value, files, [], at, root).length === 0)) fail('anyOf');
  if (schema.allOf) schema.allOf.forEach(s => checkSchema(s, value, files, errors, at, root));
  if (Object.hasOwn(schema, 'const') && value !== schema.const) fail('const');
  if (schema.enum && !schema.enum.includes(value)) fail('enum');
  const matches = {
    object: value !== null && typeof value === 'object' && !Array.isArray(value),
    array: Array.isArray(value), string: typeof value === 'string',
    boolean: typeof value === 'boolean', null: value === null,
    number: typeof value === 'number' && Number.isFinite(value),
    integer: Number.isSafeInteger(value),
  };
  if (schema.type && !matches[schema.type]) { fail('type'); return errors; }
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) fail('minimum');
    if (schema.maximum !== undefined && value > schema.maximum) fail('maximum');
  }
  if (typeof value === 'string') {
    const length = [...value].length;
    if (schema.minLength !== undefined && length < schema.minLength) fail('minLength');
    if (schema.maxLength !== undefined && length > schema.maxLength) fail('maxLength');
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) fail('pattern');
    if (schema.format === 'date' && !validDate(value)) fail('date');
    if (schema.format === 'date-time' && !validInstant(value)) fail('date-time');
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) fail('minItems');
    if (schema.maxItems !== undefined && value.length > schema.maxItems) { fail('maxItems'); return errors; }
    if (schema.uniqueItems && new Set(value.map(v => JSON.stringify(v))).size !== value.length) fail('uniqueItems');
    if (schema.contains && !value.some(v => checkSchema(schema.contains, v, files, [], at, root).length === 0)) fail('contains');
    if (schema.items) value.forEach((v, i) => checkSchema(schema.items, v, files, errors, `${at}[${i}]`, root));
  } else if (matches.object) {
    for (const key of schema.required || []) {
      if (!Object.hasOwn(value, key) && errors.length < 32) errors.push({ path: `${at}.${key}`, rule: 'required' });
    }
    for (const key of Object.keys(value)) {
      if (Object.hasOwn(schema.properties || {}, key)) {
        checkSchema(schema.properties[key], value[key], files, errors, `${at}.${key}`, root);
      } else if (schema.additionalProperties === false) fail('additionalProperties');
    }
  }
  return errors;
}

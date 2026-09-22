import type { JsonSchema } from './json-schema.js';

/**
 * JSON Schema -> Dart emitter.
 *
 * Deliberately narrow: it understands exactly the shapes our contract uses and throws on
 * anything else. A generator that silently guesses at an unfamiliar shape would produce
 * Dart that compiles and is wrong, which is the failure mode this whole pipeline exists to
 * prevent. If this throws, teach it the shape on purpose.
 */

const RESERVED = new Set([
  'is', 'in', 'default', 'class', 'new', 'final', 'const', 'var', 'this', 'switch', 'return',
]);

function camel(name: string): string {
  return name.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

function dartFieldName(name: string): string {
  const c = camel(name);
  return RESERVED.has(c) ? `${c}_` : c;
}

function pascal(name: string): string {
  const c = camel(name);
  return c.charAt(0).toUpperCase() + c.slice(1);
}

interface Ctx {
  root: JsonSchema;
  emitted: Map<string, string>;
  order: string[];
}

/** Resolves a JSON pointer such as `#/definitions/Operation/anyOf/0/properties/opId`. */
function resolvePointer(root: JsonSchema, ref: string): JsonSchema {
  if (!ref.startsWith('#/')) throw new Error(`unsupported $ref (not a local pointer): ${ref}`);
  let node: any = root;
  for (const rawSeg of ref.slice(2).split('/')) {
    const seg = rawSeg.replace(/~1/g, '/').replace(/~0/g, '~');
    node = Array.isArray(node) ? node[Number(seg)] : node?.[seg];
    if (node === undefined) throw new Error(`$ref does not resolve: ${ref}`);
  }
  return node as JsonSchema;
}

/**
 * A $ref naming a top-level definition maps to a generated class. Any other pointer is
 * zod-to-json-schema deduplicating a repeated inline shape (every uuidv7 field, say), so we
 * follow it and inline the result.
 */
function namedRef(ref: string): string | null {
  const m = /^#\/definitions\/([A-Za-z0-9_]+)$/.exec(ref);
  return m ? m[1] : null;
}

function deref(schema: JsonSchema, ctx: Ctx): JsonSchema {
  let s = schema;
  while (s.$ref && !namedRef(s.$ref)) s = resolvePointer(ctx.root, s.$ref);
  return s;
}

/** Splits `anyOf: [X, {type:'null'}]` into its non-null branch. */
function unwrapNullable(schema: JsonSchema): { inner: JsonSchema; nullable: boolean } {
  if (Array.isArray(schema.anyOf) && schema.anyOf.length === 2) {
    const nullIdx = schema.anyOf.findIndex((s: JsonSchema) => s.type === 'null');
    if (nullIdx !== -1) return { inner: schema.anyOf[1 - nullIdx], nullable: true };
  }
  if (Array.isArray(schema.type) && schema.type.includes('null')) {
    const t = schema.type.filter((x: string) => x !== 'null');
    return { inner: { ...schema, type: t.length === 1 ? t[0] : t }, nullable: true };
  }
  return { inner: schema, nullable: false };
}

/** An anyOf of objects that each pin the same property to a string const. */
function discriminatorOf(schema: JsonSchema): string | null {
  if (!Array.isArray(schema.anyOf) || schema.anyOf.length < 2) return null;
  const branches = schema.anyOf as JsonSchema[];
  if (!branches.every((b) => b.type === 'object' && b.properties)) return null;
  return (
    Object.keys(branches[0].properties).find((k) =>
      branches.every((b) => typeof b.properties?.[k]?.const === 'string'),
    ) ?? null
  );
}

interface Resolved {
  type: string;
  nullable: boolean;
  /** Which shape family, so fromJson/toJson know what to emit. */
  kind: 'primitive' | 'class' | 'list';
  itemType?: string;
  itemKind?: 'primitive' | 'class';
  itemSchema?: JsonSchema;
}

function resolveType(schemaIn: JsonSchema, ctx: Ctx, path: string): Resolved {
  // Peel nullability repeatedly: an optional field whose schema is already `.nullable()`
  // arrives wrapped twice, and one `?` in Dart covers both.
  let inner = schemaIn;
  let nullable = false;
  for (;;) {
    const step = unwrapNullable(deref(inner, ctx));
    inner = deref(step.inner, ctx);
    if (!step.nullable) break;
    nullable = true;
  }
  const q = nullable ? '?' : '';

  if (inner.$ref) {
    const name = namedRef(inner.$ref)!;
    ensureDefinitionEmitted(name, ctx);
    return { type: `${name}${q}`, nullable, kind: 'class' };
  }
  if (Array.isArray(inner.enum) || typeof inner.const === 'string') {
    // Enum values stay Dart Strings on purpose: an unknown future value from a newer server
    // must be a rejected operation, not a client-side crash on an unmapped enum case.
    return { type: `String${q}`, nullable, kind: 'primitive' };
  }
  if (inner.type === 'string') return { type: `String${q}`, nullable, kind: 'primitive' };
  if (inner.type === 'boolean') return { type: `bool${q}`, nullable, kind: 'primitive' };
  if (inner.type === 'integer') return { type: `int${q}`, nullable, kind: 'primitive' };
  if (inner.type === 'number') {
    throw new Error(
      `${path}: a bare "number" reached the Dart emitter. Money and quantities are integers ` +
        `(docs/04 §3, guardian G4) — put .int() on the Zod schema.`,
    );
  }
  if (inner.type === 'array') {
    const item = resolveType(inner.items, ctx, `${path}Item`);
    return {
      type: `List<${item.type}>${q}`,
      nullable,
      kind: 'list',
      itemType: item.type,
      itemKind: item.kind === 'class' ? 'class' : 'primitive',
      itemSchema: inner.items,
    };
  }
  if (discriminatorOf(inner)) {
    const name = pascal(path);
    emitUnion(name, inner, ctx);
    return { type: `${name}${q}`, nullable, kind: 'class' };
  }
  if (inner.type === 'object' || inner.properties) {
    const name = pascal(path);
    emitClass(name, inner, ctx);
    return { type: `${name}${q}`, nullable, kind: 'class' };
  }
  throw new Error(`${path}: unsupported schema ${JSON.stringify(inner).slice(0, 200)}`);
}

function fromJsonExpr(r: Resolved, access: string): string {
  const base = (() => {
    switch (r.kind) {
      case 'class':
        return `${r.type.replace(/\?$/, '')}.fromJson(${access} as Map<String, dynamic>)`;
      case 'list': {
        const bare = r.itemType!.replace(/\?$/, '');
        const each =
          r.itemKind === 'class'
            ? `${bare}.fromJson(e as Map<String, dynamic>)`
            : `e as ${bare}`;
        return `(${access} as List<dynamic>).map((e) => ${each}).toList()`;
      }
      default:
        return `${access} as ${r.type.replace(/\?$/, '')}`;
    }
  })();
  return r.nullable ? `${access} == null ? null : ${base}` : base;
}

function toJsonExpr(r: Resolved, field: string): string {
  switch (r.kind) {
    case 'class':
      return r.nullable ? `${field}?.toJson()` : `${field}.toJson()`;
    case 'list': {
      if (r.itemKind !== 'class') return field;
      return r.nullable
        ? `${field}?.map((e) => e.toJson()).toList()`
        : `${field}.map((e) => e.toJson()).toList()`;
    }
    default:
      return field;
  }
}

function ensureDefinitionEmitted(name: string, ctx: Ctx): void {
  if (ctx.emitted.has(name)) return;
  const def = ctx.root.definitions?.[name];
  if (!def) throw new Error(`$ref to unknown definition: ${name}`);
  if (discriminatorOf(def)) emitUnion(name, def, ctx);
  else emitClass(name, def, ctx);
}

function emitClass(name: string, schema: JsonSchema, ctx: Ctx, extendsBase?: string): void {
  if (ctx.emitted.has(name)) return;
  ctx.emitted.set(name, ''); // reserve the name first so self-references terminate
  ctx.order.push(name);

  const props: Record<string, JsonSchema> = schema.properties ?? {};
  const required: string[] = schema.required ?? [];

  const fields = Object.entries(props).map(([jsonName, propSchema]) => {
    const optional = !required.includes(jsonName);
    const declared = optional ? { anyOf: [propSchema, { type: 'null' }] } : propSchema;
    const r = resolveType(declared, ctx, `${name}${pascal(jsonName)}`);
    return { jsonName, dartName: dartFieldName(jsonName), r, doc: (propSchema as any).description };
  });

  const ctor = fields
    .map((f) => `    ${f.r.nullable ? '' : 'required '}this.${f.dartName},`)
    .join('\n');
  const decls = fields
    .map((f) => `${f.doc ? `  /// ${f.doc}\n` : ''}  final ${f.r.type} ${f.dartName};`)
    .join('\n');
  const from = fields
    .map((f) => `        ${f.dartName}: ${fromJsonExpr(f.r, `json['${f.jsonName}']`)},`)
    .join('\n');
  const to = fields
    .map((f) => `        '${f.jsonName}': ${toJsonExpr(f.r, f.dartName)},`)
    .join('\n');
  const propsList = fields.map((f) => f.dartName).join(', ');

  const head = extendsBase ? `class ${name} extends ${extendsBase} {` : `class ${name} {`;
  const superCall = extendsBase ? '  super();\n' : '';

  ctx.emitted.set(
    name,
    `${schema.description ? `/// ${schema.description}\n` : ''}${head}
  const ${name}({
${ctor}
  })${extendsBase ? ' : super()' : ''};

${decls}

  factory ${name}.fromJson(Map<String, dynamic> json) => ${name}(
${from}
      );

${extendsBase ? '  @override\n' : ''}  Map<String, dynamic> toJson() => <String, dynamic>{
${to}
      };

  List<Object?> get _props => <Object?>[${propsList}];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ${name} && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => '${name}(\${toJson()})';
}`.replace(superCall, ''),
  );
}

function emitUnion(name: string, schema: JsonSchema, ctx: Ctx): void {
  if (ctx.emitted.has(name)) return;
  const disc = discriminatorOf(schema);
  if (!disc) throw new Error(`${name}: anyOf without a string discriminator is unsupported`);

  ctx.emitted.set(name, '');
  ctx.order.push(name);

  const branches = (schema.anyOf as JsonSchema[]).map((b) => ({
    value: b.properties[disc].const as string,
    className: `${name}${pascal(b.properties[disc].const)}`,
    schema: b,
  }));

  for (const b of branches) emitClass(b.className, b.schema, ctx, name);

  const cases = branches
    .map((b) => `      case '${b.value}':\n        return ${b.className}.fromJson(json);`)
    .join('\n');

  ctx.emitted.set(
    name,
    `/// Discriminated on \`${disc}\`.
///
/// An unrecognised discriminator throws instead of being skipped: an operation we cannot
/// parse is an incident to surface, never a transaction to drop on the floor.
sealed class ${name} {
  const ${name}();

  Map<String, dynamic> toJson();

  static ${name} fromJson(Map<String, dynamic> json) {
    switch (json['${disc}'] as String) {
${cases}
      default:
        throw FormatException('unknown ${disc}: \${json['${disc}']}');
    }
  }
}`,
  );
}

const HELPERS = `bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? value) {
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}`;

export function emitDart(contract: JsonSchema, contractVersion: string): string {
  const defs: Record<string, JsonSchema> = contract.definitions ?? {};
  const ctx: Ctx = { root: contract, emitted: new Map(), order: [] };

  for (const name of Object.keys(defs)) ensureDefinitionEmitted(name, ctx);

  const body = ctx.order.map((n) => ctx.emitted.get(n)).join('\n\n');

  return `// GENERATED FILE — DO NOT EDIT.
//
// Generated from packages/contracts/src by \`pnpm gen:contracts\`.
// Edit the Zod schemas there and regenerate; CI fails if this file is stale (ADR-010).
//
// The sync envelope is a CONTROLLED ARTIFACT (docs/06-delivery-plan.md §7): changing it
// needs an ADR, both-side contract tests including N-1 (ADR-009), a guardian-suite update,
// two reviews, and an RTM entry.
//
// Contract version: ${contractVersion}

// ignore_for_file: unnecessary_cast, lines_longer_than_80_chars, unnecessary_this

/// The contract version this client speaks, sent as the \`x-contract-version\` header.
const String kContractVersion = '${contractVersion}';

${HELPERS}

${body}
`;
}

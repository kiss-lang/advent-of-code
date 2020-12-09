package kiss;

#if macro
import haxe.Exception;
import haxe.macro.Context;
import haxe.macro.Expr;
import kiss.Stream;
import kiss.Reader;
import kiss.FieldForms;
import kiss.SpecialForms;
import kiss.Macros;
import kiss.CompileError;

using kiss.Helpers;
using kiss.Reader;
using tink.MacroApi;

typedef ExprConversion = (ReaderExp) -> Expr;

typedef KissState = {
    className:String,
    readTable:Map<String, ReadFunction>,
    fieldForms:Map<String, FieldFormFunction>,
    specialForms:Map<String, SpecialFormFunction>,
    macros:Map<String, MacroFunction>,
    wrapListExps:Bool
};

class Kiss {
    public static function defaultKissState():KissState {
        var className = Context.getLocalClass().get().name;

        var k = {
            className: className,
            readTable: Reader.builtins(),
            fieldForms: FieldForms.builtins(),
            specialForms: SpecialForms.builtins(),
            macros: Macros.builtins(),
            wrapListExps: true
        };

        // Helpful aliases
        k.defAlias("print", Symbol("Prelude.print"));
        k.defAlias("groups", Symbol("Prelude.groups"));
        k.defAlias("zip", Symbol("Prelude.zip"));
        k.defAlias("map", Symbol("Lambda.map"));
        k.defAlias("filter", Symbol("Lambda.filter")); // TODO use truthy as the default filter function
        k.defAlias("has", Symbol("Lambda.has"));
        k.defAlias("count", Symbol("Lambda.count"));

        return k;
    }

    /**
        Build a Haxe class from a corresponding .kiss file
    **/
    macro static public function build(kissFile:String, ?k:KissState):Array<Field> {
        try {
            var classFields = Context.getBuildFields();
            var stream = new Stream(kissFile);

            if (k == null)
                k = defaultKissState();

            Reader.readAndProcess(stream, k.readTable, (nextExp) -> {
                #if test
                Sys.println(nextExp.def.toString());
                #end
                var field = readerExpToField(nextExp, k);
                if (field != null) {
                    #if test
                    switch (field.kind) {
                        case FVar(_, expr) | FFun({ret: _, args: _, expr: expr}):
                            Sys.println(expr.toString());
                        default:
                            throw CompileError.fromExp(nextExp, 'cannot print the expression of generated field $field');
                    }
                    #end
                    classFields.push(field);
                }
            });

            return classFields;
        } catch (err:CompileError) {
            Sys.println(err);
            Sys.exit(1);
            return null; // Necessary for build() to compile
        } catch (err:UnmatchedBracketSignal) {
            Sys.println(Stream.toPrint(err.position) + ': Unmatched ${err.type}');
            Sys.exit(1);
            return null;
        } catch (err:Exception) {
            throw err; // Re-throw haxe exceptions for precise stacks
        }
    }

    static function readerExpToField(exp:ReaderExp, k:KissState):Null<Field> {
        var fieldForms = k.fieldForms;

        // Macros at top-level are allowed if they expand into a fieldform, or null like defreadermacro
        var macros = k.macros;

        return switch (exp.def) {
            case CallExp({pos: _, def: Symbol(mac)}, args) if (macros.exists(mac)):
                var expandedExp = macros[mac](exp, args, k);
                if (expandedExp != null) readerExpToField(macros[mac](expandedExp, args, k), k) else null;
            case CallExp({pos: _, def: Symbol(formName)}, args) if (fieldForms.exists(formName)):
                fieldForms[formName](exp, args, k);
            default:
                throw CompileError.fromExp(exp, 'invalid valid field form');
        };
    }

    static function readerExpToHaxeExpr(exp:ReaderExp, k:KissState):Expr {
        var macros = k.macros;
        var specialForms = k.specialForms;
        // Bind the table arguments of this function for easy recursive calling/passing
        var convert = readerExpToHaxeExpr.bind(_, k);
        var expr = switch (exp.def) {
            case Symbol(name):
                Context.parse(name, exp.macroPos());
            case StrExp(s):
                EConst(CString(s)).withMacroPosOf(exp);
            case CallExp({pos: _, def: Symbol(mac)}, args) if (macros.exists(mac)):
                convert(macros[mac](exp, args, k));
            case CallExp({pos: _, def: Symbol(specialForm)}, args) if (specialForms.exists(specialForm)):
                specialForms[specialForm](exp, args, k);
            case CallExp(func, args):
                ECall(convert(func), [for (argExp in args) convert(argExp)]).withMacroPosOf(exp);

            /*
                // Typed expressions in the wild become casts:
                case TypedExp(type, innerExp):
                    ECast(convert(innerExp), if (type.length > 0) Helpers.parseComplexType(type, exp) else null).withMacroPosOf(wholeExp);
             */
            case ListExp(elements):
                var isMap = false;
                var arrayDecl = EArrayDecl([
                    for (elementExp in elements) {
                        switch (elementExp.def) {
                            case KeyValueExp(_, _):
                                isMap = true;
                            default:
                        }
                        convert(elementExp);
                    }
                ]).withMacroPosOf(exp);
                if (!isMap && k.wrapListExps) {
                    ENew({
                        pack: ["kiss"],
                        name: "List"
                    }, [arrayDecl]).withMacroPosOf(exp);
                } else {
                    arrayDecl;
                };
            case RawHaxe(code):
                Context.parse(code, exp.macroPos());
            case FieldExp(field, innerExp):
                EField(convert(innerExp), field).withMacroPosOf(exp);
            case KeyValueExp(keyExp, valueExp):
                EBinop(OpArrow, convert(keyExp), convert(valueExp)).withMacroPosOf(exp);
            default:
                throw CompileError.fromExp(exp, 'conversion not implemented');
        };
        #if test
        // Sys.println(expr.toString()); // For very fine-grained codegen inspection--slows compilation a lot.
        #end
        return expr;
    }

    public static function forCaseParsing(k:KissState):KissState {
        var copy = Reflect.copy(k);
        copy.wrapListExps = false;
        return copy;
    }

    public static function convert(k:KissState, exp:ReaderExp) {
        return readerExpToHaxeExpr(exp, k);
    }
}
#end

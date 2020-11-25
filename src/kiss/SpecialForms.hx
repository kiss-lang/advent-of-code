package kiss;

import haxe.macro.Expr;
import haxe.macro.Context;
import kiss.Reader;
import kiss.Types;
import uuid.Uuid;

using kiss.Reader;
using kiss.Helpers;
using kiss.Prelude;

// Special forms convert Kiss reader expressions into Haxe macro expressions
typedef SpecialFormFunction = (args:Array<ReaderExp>, convert:ExprConversion) -> Expr;

class SpecialForms {
    public static function builtins() {
        var map:Map<String, SpecialFormFunction> = [];

        map["begin"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            pos: Context.currentPos(),
            expr: EBlock([for (bodyExp in args) convert(bodyExp)])
        };

        map["nth"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            pos: Context.currentPos(),
            expr: EArray(convert(args[0]), convert(args[1]))
        };

        // TODO first through tenth

        // TODO special form for object declaration

        map["new"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length < 1) {
                throw CompileError.fromArgs(args, '(new [type] constructorArgs...) is missing a type!');
            }
            var classType = switch (args[0].def) {
                case Symbol(name): name;
                default: throw CompileError.fromExp(args[0], 'first arg in (new [type] ...) should be a class to instantiate');
            };
            ENew(Helpers.parseTypePath(classType, args[0]), args.slice(1).map(convert)).withContextPos();
        };

        // TODO this doesn't give an arg length warning
        map["set"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            EBinop(OpAssign, convert(args[0]), convert(args[1])).withContextPos();
        };

        // TODO allow var bindings to destructure lists and key-value pairs
        function toVar(nameExp:ReaderExp, valueExp:ReaderExp, isFinal:Bool, convert:ExprConversion) {
            return {
                name: switch (nameExp.def) {
                    case Symbol(name) | TypedExp(_, {pos: _, def: Symbol(name)}):
                        name;
                    default:
                        throw CompileError.fromExp(nameExp, 'expected a symbol or typed symbol for variable name in a var binding');
                },
                type: switch (nameExp.def) {
                    case TypedExp(type, _):
                        Helpers.parseComplexType(type, nameExp);
                    default: null;
                },
                isFinal: isFinal,
                expr: convert(valueExp)
            };
        }

        // TODO this doesn't give an arg length warning
        map["deflocal"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            var valueIndex = 1;
            var isFinal = switch (args[1].def) {
                case MetaExp("mut"):
                    valueIndex += 1;
                    false;
                default:
                    true;
            };
            EVars([toVar(args[0], args[valueIndex], isFinal, convert)]).withContextPos();
        };

        // TODO this doesn't have an arg length check
        map["let"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            var bindingListIndex = 0;
            // If the first arg of (let... ) is &mut, make the bindings mutable.
            var isFinal = switch (args[0].def) {
                case MetaExp("mut"):
                    bindingListIndex += 1;
                    false;
                default:
                    true;
            };
            var bindingList = switch (args[bindingListIndex].def) {
                case ListExp(bindingExps) if (bindingExps.length > 0 && bindingExps.length % 2 == 0):
                    bindingExps;
                default:
                    throw CompileError.fromExp(args[bindingListIndex], 'let bindings should be a list expression with an even number of sub expressions');
            };
            var bindingPairs = bindingList.groups(2);
            var varDefs = [
                for (bindingPair in bindingPairs)
                    toVar(bindingPair[0], bindingPair[1], isFinal, convert)
            ];

            var body = args.slice(bindingListIndex + 1);
            if (body.length == 0) {
                throw CompileError.fromArgs(args, '(let....) expression needs a body');
            }

            EBlock([EVars(varDefs).withContextPos(), EBlock(body.map(convert)).withContextPos()]).withContextPos();
        };

        // TODO special form for lambda

        // TODO special form for for loop
        // TODO special form for list comprehension
        // ^It would be nice if these were both DRY and supported list and keyvalue unpacking

        // TODO special form for while loop

        // TODO special form for do-while loop

        // TODO special form for switch

        // Type check syntax:
        map["the"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length != 2) {
                throw CompileError.fromArgs(args, '(the [type] [value]) expression has wrong number of arguments');
            }
            ECheckType(convert(args[1]), switch (args[0].def) {
                case Symbol(type): Helpers.parseComplexType(type, args[0]);
                default: throw CompileError.fromExp(args[0], 'first argument to (the... ) should be a valid type');
            }).withContextPos();
        };

        map["try"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length == 0) {
                throw CompileError.fromArgs(args, '(try...) expression has nothing to try');
            }
            var tryKissExp = args[0];
            var catchKissExps = args.slice(1);
            ETry(convert(tryKissExp), [
                for (catchKissExp in catchKissExps) {
                    switch (catchKissExp.def) {
                        case CallExp({pos: _, def: Symbol("catch")}, catchArgs):
                            {
                                name: switch (catchArgs[0].def) {
                                    case ListExp([
                                        {
                                            pos: _,
                                            def: Symbol(name) | TypedExp(_, {pos: _, def: Symbol(name)})
                                        }
                                    ]): name;
                                    default: throw CompileError.fromExp(catchArgs[0], 'first argument to (catch... ) should be a one-element argument list');
                                },
                                type: switch (catchArgs[0].def) {
                                    case ListExp([{pos: _, def: TypedExp(type, _)}]):
                                        Helpers.parseComplexType(type, catchArgs[0]);
                                    default: null;
                                },
                                expr: convert(CallExp(Symbol("begin").withPos(catchArgs[1].pos), catchArgs.slice(1)).withPos(catchArgs[1].pos))
                            };
                        default:
                            throw CompileError.fromExp(catchKissExp,
                                'expressions following the first expression in a (try... ) should all be (catch... ) expressions');
                    }
                }
            ]).withContextPos();
        };

        map["throw"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length != 1) {
                throw CompileError.fromArgs(args, 'throw expression should only throw one value');
            }
            EThrow(convert(args[0])).withContextPos();
        };

        map["<"] = foldComparison("_min");
        map["<="] = foldComparison("min");
        map[">"] = foldComparison("_max");
        map[">="] = foldComparison("max");
        map["="] = foldComparison("_eq");

        map["if"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length < 2 || args.length > 3) {
                throw CompileError.fromArgs(args, '(if [cond] [then] [?else]) expression has wrong number of arguments');
            }

            var condition = macro Prelude.truthy(${convert(args[0])});
            var thenExp = convert(args[1]);
            var elseExp = if (args.length > 2) convert(args[2]) else null;

            macro if ($condition)
                $thenExp
            else
                $elseExp;
        };

        map["not"] = (args:Array<ReaderExp>, convert:ExprConversion) -> {
            if (args.length != 1)
                throw CompileError.fromArgs(args, '(not... ) only takes one argument, not $args');
            var condition = convert(args[0]);
            var truthyExp = macro Prelude.truthy($condition);
            macro !$truthyExp;
        };

        return map;
    }

    static function foldComparison(func:String) {
        return (args:Array<ReaderExp>, convert:ExprConversion) -> {
            pos: Context.currentPos(),
            expr: EBinop(OpEq, convert(args[0]), convert(CallExp(Symbol(func).withPos(args[0].pos), args).withPos(args[0].pos)))
        };
    }
}

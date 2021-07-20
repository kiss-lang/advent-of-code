package kiss.cloner;

import Array;
import haxe.ds.ObjectMap;
import Type.ValueType;
import haxe.ds.IntMap;
import haxe.ds.StringMap;

class Cloner {
    var cache:ObjectMap<Dynamic, Dynamic>;
    var classHandles:Map<String, Dynamic->Dynamic>;
    var stringMapCloner:MapCloner<String>;
    var intMapCloner:MapCloner<Int>;

    public function new():Void {
        stringMapCloner = new MapCloner(this, StringMap);
        intMapCloner = new MapCloner(this, IntMap);
        classHandles = new Map<String, Dynamic->Dynamic>();
        classHandles.set('String', returnString);
        classHandles.set('Array', cloneArray);
        classHandles.set('haxe.ds.StringMap', stringMapCloner.clone);
        classHandles.set('haxe.ds.IntMap', intMapCloner.clone);
    }

    function returnString(v:String):String {
        return v;
    }

    public function clone<T>(v:T):T {
        cache = new ObjectMap<Dynamic, Dynamic>();
        var outcome:T = _clone(v);
        cache = null;
        return outcome;
    }

    public function _clone<T>(v:T):T {
        #if js
        if (Std.is(v, String))
            return v;
        #end

        #if (neko || cs)
        try {
            if (Type.getClassName(cast v) != null)
                return v;
        } catch (e:Dynamic) {}
        #else
        if (Type.getClassName(cast v) != null)
            return v;
        #end
        switch (Type.typeof(v)) {
            case TNull:
                return null;
            case TInt:
                return v;
            case TFloat:
                return v;
            case TBool:
                return v;
            case TObject:
                return handleAnonymous(v);
            case TFunction:
                return v;
            case TClass(c):
                if (!cache.exists(v))
                    cache.set(v, handleClass(c, v));
                return cache.get(v);
            case TEnum(e):
                return v;
            case TUnknown:
                throw 'Cannot clone object of unknown type $v';
        }
    }

    function handleAnonymous(v:Dynamic):Dynamic {
        var properties:Array<String> = Reflect.fields(v);
        var anonymous:Dynamic = {};
        for (i in 0...properties.length) {
            var property:String = properties[i];
            Reflect.setField(anonymous, property, _clone(Reflect.getProperty(v, property)));
        }
        return anonymous;
    }

    function handleClass<T>(c:Class<T>, inValue:T):T {
        var handle:T->T = classHandles.get(Type.getClassName(c));
        if (handle == null)
            handle = cloneClass;
        return handle(inValue);
    }

    function cloneArray<T>(inValue:Array<T>):Array<T> {
        var array:Array<T> = inValue.copy();
        for (i in 0...array.length)
            array[i] = _clone(array[i]);
        return array;
    }

    function cloneClass<T>(inValue:T):T {
        var classValue = Type.getClass(inValue);
        var outValue:T = Type.createEmptyInstance(classValue);
        var fields:Array<String> = Type.getInstanceFields(classValue);
        for (field in fields) {
            var property = Reflect.getProperty(inValue, field);
            try {
                Reflect.setField(outValue, field, _clone(property));
            } catch (s) {
                // There will be errors on C++ and C# when trying to assign to a member function.
                // They're not important, because the function will already be on the clone.
                // However, some types won't clone properly on C#, and if that becomes a problem, tests should fail
                #if cs
                if (field != "breakPoints" && Std.string(s) == "Specified cast is not valid.") {
                    throw 'Failed to clone field $field on $inValue';
                }
                #end
            }
        }
        return outValue;
    }
}

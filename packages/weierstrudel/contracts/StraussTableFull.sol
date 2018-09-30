pragma solidity ^0.4.23;

contract StraussTableFullInterface {
    function generateTablePure(uint[2][] points) public pure returns (uint[2][]) {}
}

/// @dev Ok! Time to generate a full precomputed table. What an unholy mess of nonsense...
contract StraussTableFull {
    function() external payable {
        assembly {
        // Ok, what the hell are we doing....
        // to start with we want to load up points...
        // we use 3 words as scratch space for the strauss_table_single algorithm, and 1 word for table pointer
        // also iterator storage, so we start our offset table at 0xa0
        // also return destination. Ok let's define some scratch space...
        // 0x00 - 0x60: strauss_single stratch space
        // 0x60 - 0x80: dz table pointer
        // 0x80 - 0xa0: iterator location
        // 0xa0 - 0xc0: jump destination scratch space
        // 0xc0 - 0xe0: precompute table pointer
        // 0xe0 - 0x100: some kind of iterator storage. who knows
        // 0xe0 - ???: dz table

        // we need 8*2 words per array index for points
        // we need 8 words per array index for dz scalar
        0x100 0x60 mstore       // dz table starts at 0x100
        0x24 calldataload 0x100 mul               // 8-words * size
        0x120 add
        dup1 0xc0 mstore  // store (0x100 * size * 2 + 0x120) at 0xc0
        0xe0 mstore       // we mutate 0xc0 so also store at 0xe0 for future reference

        // now we want to...loop over our input points. We can assume the points are affine, full algorithm will validate this
        // what is the calldata map?
        // 0x04 - 0x24 = location of array (0x24)
        // 0x24 - 0x44 = size of array
        // 0x44 - ???? = dynamic array
        // we can cheekily use calldatasize to get our iterator endpoint.
        // we know that our iterator starts at 0x44
        1                       // points are affine so start with z-coord of 1
        0x44       // i

        dup1 0x80 mstore        // store it because, our stack state is going to get MESSED up pretty damn quickly
        dup1 calldatasize eq no_data jumpi
         // ... we need this
        // so we can assume we have not in fact finished if we hit this point.
        // so... let's load up a point?
        // start with x
    phase_one_start:
        calldataload       // x z'

        // Now! We do have a z-coordinate. We want to scale this point by the final z-coordinate of the previous point
        // what the fuck is that?
        // well it's going to be the last thing on the stack    // x z'
        // we also need to scale y and x by this coordinate
        21888242871839275222246405745257275088696311157297823662689037894645226208583 // hello again, strange prime field constant...
        dup1                            // p p x z
        dup4                            // z p p x z
        dup1                            // z z p p x z
        mulmod                          // zz p x z
        dup2                            // p zz p x z
        dup1                            // p p zz p x z
        dup3                            // zz p p zz p x z
        dup7                            // z zz p p zz p x z
        mulmod                          // zzz p zz p x z
        
        0x80 mload 0x20 add calldataload// y zzz p zz p x z
        mulmod                          // y' zz p x z
        swap3                           // x zz p y' z
        mulmod                          // x' y' z
        swap2                           // z y' x'  // consume z with next function call, we don't need it anymore

        // this 'function' call is going to add a bunch of nonsense onto the stack - can't leave return destination on back of stack
        // so store it at 0xa0
        strauss_table_single_return 0xa0 mstore
        strauss_table_single jump       // away we go!
        strauss_table_single_return:    // and back we come, with shiny new variables on our stack
        0x80 mload                      // let's recover our iterator
                                        // stack state: i z <£$£%£>
        0x40 add                        // increase by 1 point: i' ?? ? ??
        dup1 0x80 mstore                // store the increased value


        0x01 0x60 mload mstore          // debug testing...
        0x60 mload 0x20 add 0x60 mstore

        calldatasize dup2 lt phase_one_start jumpi

        // if we fall though to here, we've finished iterating! Great!
        pop // we have 'i' on the stack, can probably optimize this out

        // now the fun starts...
        // we need to concatenate up dz terms to calculate an accumulated z-offset
        // so that we can scale every coordinate to the same z-term
        0x00 mstore // the final z-coordinate is our *global* z-coord. So let's store that.
        // good god. this is going to be ugly
        0x20 0x60 mload sub  // this is the pointer to the end of dz. We need to work backwards, multiplying up as we go
        // 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0 add  // add -32 because I'm too lazy to swap variables
        // stack state i' y x ...
        swap2                           // x y i'
        swap1                           // y x i' // we'll optimize this stuff out

        // dup3 mload                      // z' y x i
        // first one will not have a z-scalar
        0x01

    rescale_and_store:
        21888242871839275222246405745257275088696311157297823662689037894645226208583 // hello again, strange prime field constant...
        dup1                            // p p z y x
        dup3                            // z p p z y x
        dup1                            // z z p p z y x
        mulmod                          // zz p z y x
        21888242871839275222246405745257275088696311157297823662689037894645226208583
        dup2                            // zz p zz p z y x
        dup5                            // z zz p zz p z y x
        mulmod                          // zzz zz p z y x
        swap5                           // x zz p z y zzz

        // ### debug
        // ### debug
        mulmod                          // x' z y zzz
        0xc0 mload                      // m x' z y zzz
        mstore                          // z y zzz

        swap2                           // zzz y z
        21888242871839275222246405745257275088696311157297823662689037894645226208583 // p zzz y z
        swap2                           // y zzz p z

        // ### debug
        mulmod                          // y' z
        0xc0 mload 0x20 add             // m' y' z
        dup1 0x20 add 0xc0 mstore       // m' y' z
        mstore                          // z i y x


        // we've now reduced down a single point coordinate. We need to figure out if we need to jump again
        swap1                           // i z y x
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0 add  // i' z y x
        dup1 /* 0xe0 mload */ 0xe0 eq end_subroutine jumpi
                                        // i z y x
        // we're not at the end so scale up our running dz scalar by next dz value
        swap3                           // x z y i

        dup4 mload                      // dz x z y i


        21888242871839275222246405745257275088696311157297823662689037894645226208583
                                        // p dz x z y i
        swap2                           // x dz p z y i
        swap3                           // z dz p x y i

        mulmod                          // z' y x i

        // todo: optimize these swaps away! gah!
        swap2                           // x y z' i
        swap1                           // y x z' i
        swap2                           // z' x y i
        
        rescale_and_store jump          // ??? bleurgh

    end_subroutine:
        // should probably return something here
        // we need to reconstruct a dynamic array according to the smart contract ABI
        0x40
        0xe0 mload                      // get start of point array on stack
        0x40
        dup2 0xc0 mload sub             // get difference between start and end array
        div                             // and divide by 64. stack = <size> <start>
        

        0x20 dup3 sub mstore            // store size 32 bytes before start of array. stack = <start>
        sub                             // stack = <start - 64>
        
        0x20 dup2 mstore                // store '32' 64 bytes before start of array (location of array)

        0x20 0x40 dup3 sub mstore       // store '32' 64 bytes before start of array (location of array). stack = <start>
        dup1 0xc0 mload sub             // stack = <size> <start>

        swap1
        return


    some_kind_of_label:



        no_data: // god knows what we're doing here
        // the assembly code to compute a single table iteration. If we hide it at the bottom we can pretend it doesn't exist, right?.....
            0x00 0x00 revert // shouldn't get getting here without an explicit jump...
        strauss_table_single:
            // stack state: z y x

            dup3 dup3 dup3 
            // stack state: z3 y3 x3 z y x

            //bn128_dbl_strauss:
            // stack state: z y x
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            dup3 dup1// stack state: y y p z y x
            mulmod
            // stack state: t1 z y x
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            dup2
            // stack state: t1 p t1 z y x
            4 mul
            // stack state: t2 p t1 z y x (t2 = 4x overloaded)
            dup2 dup1 dup1
            // stack state: p p p t2 p t1 z y x
            dup4 dup10
            // stack state: x t2 p p p t2 p t1 z y x
            mulmod
            // stack state: (x.t2) p p t2 p t1 z y x
            dup2
            sub

            // stack state: t3 p p t2 p t1 z y x
            swap8
            // stack state: x p p t2 p t1 z y t3
            dup1 mulmod
            // stack state: x^2 p t2 p t1 z y t3
            3 mul
            // stack state: t4 p t2 p t1 z y t3 (t4 = 3x overloaded)
            dup2 dup2 dup1
            // stack state: t4 t4 p t4 p t2 p t1 z y t3
            mulmod
            // stack state: (t4^2) t4 p t2 p t1 z y t3
            dup9 dup1 add
            // stack state: 2t3 (t4^2) t4 p t2 p t1 z y t3
            add
            // stack state: x3 t4 p t2 p t1 z y t3 (x3 = 3x overloaded)

            swap8
            // stack state: t3 t4 p t2 p t1 z y x3
            dup9 add
            // stack state: (x3+t3) t4 p t2 p t1 z y x3 (x3+t3 = 4x overloaded)
            mulmod
            // stack state: y3' t2 p t1 z y x3
            swap3
            // stack state: t1 t2 p y3' z y x3
            mulmod
            // stack state: t1 y3' z y x3
            dup1 add
            // stack state: 2t1 y3' z y x3
            add
            // stack state: -y3 z y x3
            // we need to negate (-y3), which is 3x overloaded, so subtract from 3p
            65664728615517825666739217235771825266088933471893470988067113683935678625749
            sub
            // stack state: y3 z y x3
            swap2
            // stack state: y z y3 x3
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            // stack state: p y z y3 x3
            swap2
            // stack state: z y p y3 x3
            dup1 add
            // stack state: 2z y p y3 x3
            mulmod
            // stack state: z3 y3 x3

            // we now have zd yd xd z1 y1 x1 (2P 1P) on the stack
            // we want to calculate 3P, 5P, 7P ... etc, by adding 2P to an accumulator
            // if we scale 1P's x and y coordinates by zd then we can tread zd yd as affine
            // and only re-scale the z'coord of the last point (the one we use)
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            dup1    // p p zd yd xd z1 y1 x1
            dup3    // zd p p zd yd xd z1 y1 x1
            dup1    // zd zd p p zd yd xd z1 y1 x1
            mulmod  // zd^2 p zd yd xd z1 y1 x1
            dup2    // p zd^2 p zd yd xd z1 y1 x1
            dup4    // zd p zd^2 p zd yd xd z1 y1 x1
            dup3    // zd^2 zd p zd^2 p zd yd xd z1 y1 x1
            mulmod  // zd^3 zd^2 p zd yd xd z1 y1 x1

            swap8   // x1 zd^2 p zd yd xd z1 y1 zd^3
            mulmod  // x' zd yd xd z1 y1 zd^3
            swap6   // zd^3 zd yd xd z1 y1 x'
            21888242871839275222246405745257275088696311157297823662689037894645226208583
                    // p zd^3 zd yd xd z1 y1 x'
            swap2   // zd zd^3 p yd xd z1 y1 x'
            swap6   // y1 zd^3 p yd xd z1 zd x'
            mulmod  // y' yd xd z1 zd x'

            // ### HACKY WORKAROUND. Mixed Addition routine expects y to be 3x overloaded! Fix fix fix
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            add
            add

            swap4   // zd yd xd z1 y' x'


            0x40 mstore // yd xd z1 y' x'
            0x00 mstore
            65664728615517825666739217235771825266088933471893470988067113683935678625749
            sub     // we store -xd to save a sub instruction in our mixed addition algorithm
                    // subtract 3P because x3 is 3x overloaded
            0x20 mstore

            // stack state: z1 y1 x1
            // we now want to add P and 2P, without overwriting  P
            // TODO: write a more optimized algo instead of re-using mixed add!
            // TODO: use hardcoded algo instead of jumping to save some gas
            dup3 dup3       // y1 x1 z1 y1 x1
            p3_return       // [tag] y1 x1 z1 y1 x1
            swap3           // z1 y1 x1 [tag] y1 x1 // we don't need to store z, consume it
            // stack state: z1 y1 x1 [tag] y1 x1
            bn128_add_strauss jump

        // y3 x3 z3

        p3_return:      // y3 x3 z3 y1 x1
            swap1       // x3 y3 z3 y1 x1
            swap2       // z3 x3 y3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p5_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump
    
        p5_return:      // x3 y3 z3 y1 x1
            swap1
            swap2       // z3 y3 x3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p7_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump
    
        p7_return:      // x3 y3 z3 y1 x1
            swap1
            swap2       // z3 y3 x3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p9_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump
    
        p9_return:      // x3 y3 z3 y1 x1
            swap1
            swap2       // z3 y3 x3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p11_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump

    
        p11_return:      // x3 y3 z3 y1 x1
            swap1
            swap2       // z3 y3 x3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p13_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump
    
        p13_return:      // y3 x3 z3 y1 x1
            swap1
            swap2       // z3 y3 x3 y1 x1
            dup3 dup3   // y3 x3 z3 y3 x3 y1 x1
            p15_return swap3 // z3 y3 x3 [tag] y3 x3 y1 x1
            bn128_add_strauss jump
    
        p15_return:      // y3 x3 z3 y1 x1
            swap1
            swap2       // zf yf xf ...
            // zf is off by a factor of zd, scale up
            21888242871839275222246405745257275088696311157297823662689037894645226208583
            swap1       // z p y x
            0x40 mload  // dz z p y x
            mulmod      // zf' yf xf ... 


        // ok! So we have a ton of new points on the stack, and we need to jump back
        // problem...our return destination is waaaay too far away if we stored it on the stack
        // so load it out of 0xa0
        0xa0 mload jump

        /// @dev mixed point addition
        /// @notice expects (z1 y1 x1) to be on stack
        bn128_add_strauss:

            21888242871839275222246405745257275088696311157297823662689037894645226208583
                            // p z1 y1 x1
            dup1            // p p z1 y1 x1
            dup3            // z1 p p z1 y1 x1
            dup1            // z1 z1 p p z1 y1 x1
            mulmod          // t1 p z1 y1 x1
            dup2            // p t1 p z1 y1 x1
            dup1
            dup1
            dup1                // p p p p t1 p z1 y1 x1
            dup7                // z1 p p p p t1 p z1 y1 x1
            dup6                // t1 z1 p p p p t1 p z1 y1 x1
            mulmod              // t2 p p p t1 p z1 y1 x1
            0x00 mload          // y2 t2 p p p t1 p z1 y1 x1
            mulmod              // t2 p p t1 p z1 y1 x1
            dup7
            // 21888242871839275222246405745257275088696311157297823662689037894645226208583
            65664728615517825666739217235771825266088933471893470988067113683935678625749
            sub                 // y1 is 3x overloaded (both from dbl and add). So subtract 3p to negate
                                // -y1 t2 p p t1 p z1 y1 x1
            // NOTE: Is y1 not overloaded? I think it is?
            add                 // t2 p p t1 p z1 y1 x1
                                // t2 is 4x overloaded! any opcode involving t2 must be modular
            swap3               // t1 p p t2
            0x20 mload          // x2 t1 p p t2
            // dup3 sub            // -x2 t1 p p t2 z1 y1 x1
            mulmod              // t1 p t2 p z1 y1 x1

            dup7
            add                     // t1 p t2 p z1 y1 x1

            // t1 is the intermediate scalar that transforms z1 to z3. Cache it for later
            0x60 mload              // memory pointer
            dup2                    // t m
            dup2                    // m t m
            mstore                  // m
            0x20 add                // m'
            0x60 mstore             // store updated result


            dup2 dup1 dup1          // p p p t1 p t2 p z1 y1 x1
            dup4 dup1               // t1 t1 p p p t1 p t2 p z1 y1 x1
            mulmod                  // t3 p p t1 p t2 p z1 y1 x1
            dup2 dup5 dup3          // t3 t1 p t3 p p t1 p t2 p z1 y1 x1
            mulmod                  // t4 t3 p p t1 p t2 p z1 y1 x1
            swap10                  // x1 t3 p p t1 p t2 p z1 y1 t4
            mulmod                  // t3 p t1 p t2 p z1 y1 t4
            dup2 sub                // t3 p t1 p t2 p z1 y1 t4
            swap7                   // y1 p t1 p t2 p z1 t3 t4
            dup2 dup10              // t4 p y1 p t1 p t2 p z1 t3 t4
            dup2 dup8 dup1          // t2 t2 p t4 p y1 p t1 p t2 p z1 t3 t4
            mulmod                  // x3 t4 p y1 p t1 p t2 p z1 t3 t4

            dup11 dup1 add
            add
            addmod                  // x3 y1 p t1 p t2 p z1 t3 t4
            swap9                   // t4 y1 p t1 p t2 p z1 t3 x3
            mulmod                  // t4 t1 p t2 p z1 t3 x3
            dup3 sub                // t4 t1 p t2 p z1 t3 x3
            swap5                   // z1 t1 p t2 p t4 t3 x3
            mulmod                  // z3 t2 p t4 t3 x3
            swap4                   // t3 t2 p t4 z3 x3
            dup6                    // x3 t3 t2 p t4 z3 x3
            add                     // t3 t2 p t4 z3 x3
            mulmod                  // t3 t4 z3 x3
            add                     // y3 z3 x3 [tag]
            swap1                   // z3 y3 x3 [tag]
            swap3 jump              // y3 x3 z3
            
            pop pop pop pop pop pop
            pop pop pop pop pop pop
            pop pop pop pop pop pop
            pop pop pop pop
        }
    }
}
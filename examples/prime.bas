    PRINT "This calculates prime numbers from 2-100"
    LET I = 2
100 GOSUB 300
    IF R <> 0 THEN PRINT I
    LET I = I + 1
    IF I > 100 THEN END
    GOTO 100

    REM R = is_prime(I)
300 LET R = 1
    LET J = 2
301 IF J >= I THEN RETURN
    LET X = I / J
    IF X * J = I THEN GOTO 302
    IF X >= I THEN GOTO 302
    LET J = J + 1
    GOTO 301
302 LET R = 0
    RETURN


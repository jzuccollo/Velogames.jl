@testset "Scoring System" begin
    @test SCORING_CAT1.finish_points[1] == 640
    @test SCORING_CAT2.finish_points[1] == 480
    @test SCORING_CAT3.finish_points[1] == 320
    @test SCORING_CAT1.finish_points[30] == 12
    @test SCORING_CAT1.assist_points[1] == 90
    @test SCORING_CAT1.breakaway_points == 60
    @test length(SCORING_CAT1.finish_points) == 30
    @test SCORING_CAT1.finish_points[1] >
          SCORING_CAT2.finish_points[1] >
          SCORING_CAT3.finish_points[1]

    @test SCORING_STAGE.finish_points[1] == 3500
    @test SCORING_STAGE.assist_points == [0, 0, 0]
    @test SCORING_STAGE.breakaway_points == 0
    @test length(SCORING_STAGE.finish_points) == 30

    @test get_scoring(1) === SCORING_CAT1
    @test get_scoring(3) === SCORING_CAT3
    @test get_scoring(:stage) === SCORING_STAGE
    @test_throws ArgumentError get_scoring(0)
    @test_throws ArgumentError get_scoring(4)
    @test_throws ArgumentError get_scoring(:invalid)

    @test finish_points_for_position(1, SCORING_CAT1) == 640
    @test finish_points_for_position(31, SCORING_CAT1) == 0
    @test finish_points_for_position(0, SCORING_CAT1) == 0

    probs_certain_win = zeros(30)
    probs_certain_win[1] = 1.0
    @test expected_finish_points(probs_certain_win, SCORING_CAT1) == 640.0
    @test expected_finish_points(zeros(30), SCORING_CAT1) == 0.0
end
